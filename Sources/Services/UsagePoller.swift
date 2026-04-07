import AppKit
import Darwin
import Foundation

@Observable
@MainActor final class UsagePoller {
    enum PollState: String, Sendable {
        /// Usage is actively changing — polling every 60s.
        case active
        /// Steady state — polling every 3m.
        case normal
        /// No usage changes detected for a while — polling every 10m.
        case idle
        /// Screen locked or system asleep — polling paused.
        case paused
        /// Rate-limited by Anthropic — back off for a cooldown period.
        case rateLimited
    }

    var pollState: PollState = .normal

    private let accountStore: AccountStore
    private let historyStore: UsageHistoryStore
    private let apiClient: APIClient
    private let widgetWriter: WidgetDataWriter
    private let apiFileWriter: APIFileWriter
    let momentumProvider: MomentumProvider?
    private let tokenUsageStore: TokenUsageStore?

    private var pollTimer: Timer?
    private var historyTimer: Timer?
    private var watchdogTimer: Timer?
    /// Timestamp of the last completed poll cycle — used by the watchdog.
    private var lastPollCycleAt: Date?

    /// Consecutive failure count per account — drives exponential backoff.
    private var failureCounts: [UUID: Int] = [:]

    /// Previous 5h utilization per account — used to detect activity.
    private var previousUtilizations: [UUID: Double] = [:]


    /// How many consecutive poll cycles showed no utilization change across any account.
    var unchangedCycles: Int = 0

    private var observers: [NSObjectProtocol] = []

    /// When monitoring was last paused — used to record gaps.
    private var pausedAt: Date?

    /// Whether the current pause is from system sleep (as opposed to screen lock/display sleep).
    /// Only system sleep records a monitoring gap, since Claude Code keeps running with screen off.
    private var pausedForSystemSleep = false

    /// Whether Claude (app or CLI) is detected running on the system.
    var claudeIsRunning = false

    private static let defaultRateLimitedInterval: TimeInterval = TimeConstants.rateLimitCooldown
    /// Actual cooldown duration — updated from Retry-After header when available.
    private var rateLimitedInterval: TimeInterval = TimeConstants.rateLimitCooldown
    /// When Claude isn't running and usage is unchanged, go idle after just 1 cycle.
    private static let idleThreshold = 3
    /// Even faster idle when Claude isn't detected at all.
    private static let idleThresholdNoClaude = 1

    private static let rateLimitExpiresAtKey = DefaultsKeys.rateLimitExpiresAt
    private static let lastPollAtKey = DefaultsKeys.lastPollAt

    init(
        accountStore: AccountStore,
        historyStore: UsageHistoryStore,
        apiClient: APIClient = .shared,
        widgetWriter: WidgetDataWriter = WidgetDataWriter(),
        apiFileWriter: APIFileWriter = APIFileWriter(),
        momentumProvider: MomentumProvider? = nil,
        tokenUsageStore: TokenUsageStore? = nil
    ) {
        self.accountStore = accountStore
        self.historyStore = historyStore
        self.apiClient = apiClient
        self.widgetWriter = widgetWriter
        self.apiFileWriter = apiFileWriter
        self.momentumProvider = momentumProvider
        self.tokenUsageStore = tokenUsageStore
    }

    /// Track account count to detect when new accounts are added.
    private var lastKnownAccountCount = 0

    func start() {
        Log.poller.info("Poller starting")
        lastKnownAccountCount = accountStore.accounts.count
        observeSystemEvents()

        // Record a gap for the time the app wasn't running
        if let elapsed = Self.timeSinceLastPoll(), elapsed > 120 {
            let gapStart = Date().addingTimeInterval(-elapsed)
            let gap = MonitoringGap(start: gapStart, end: Date())
            historyStore.addGap(gap)
            historyStore.saveGaps()
            Log.poller.info("Recorded startup gap: \(String(format: "%.0f", elapsed))s")
        }

        // Poll immediately if any account is missing usage data
        let hasMissingData = accountStore.accounts.contains { $0.fiveHour == nil || $0.sevenDay == nil }

        // Restore persisted rate-limit cooldown across restarts
        let remaining = Self.remainingRateLimitCooldown()
        if remaining > 0 {
            pollState = .rateLimited
            rateLimitedInterval = remaining
            Log.poller.info("Resuming rate-limit cooldown — \(String(format: "%.0f", remaining))s remaining")
            scheduleNextPoll(delay: remaining)
        } else if hasMissingData {
            Log.poller.info("Account(s) missing usage data — polling immediately")
            scheduleNextPoll(delay: 0)
        } else if let elapsed = Self.timeSinceLastPoll() {
            // Schedule based on how long ago we last polled
            let delay = max(PollingSettings.load().normalInterval - elapsed, 5)
            Log.poller.info("Last poll was \(String(format: "%.0f", elapsed))s ago — next in \(String(format: "%.0f", delay))s")
            scheduleNextPoll(delay: delay)
        } else {
            // Never polled before — small delay then go
            scheduleNextPoll(delay: 5)
        }

        startHistoryTimer()
        startWatchdog()
    }

    func stop() {
        Log.poller.info("Poller stopping")
        removeSystemObservers()
        pollTimer?.invalidate()
        pollTimer = nil
        historyTimer?.invalidate()
        historyTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    /// Trigger an immediate poll for accounts missing data (e.g. after adding new accounts).
    func pollNewAccountsIfNeeded() {
        let hasMissing = accountStore.accounts.contains { $0.fiveHour == nil || $0.sevenDay == nil }
        guard hasMissing else { return }
        Log.poller.info("Account(s) missing usage data — polling immediately")
        unchangedCycles = 0
        if pollState == .idle { pollState = .normal }
        scheduleNextPoll(delay: 0)
    }

    /// Force an immediate poll, resetting backoff and idle state.
    func pollNow() async {
        Log.poller.info("Manual poll requested — resetting backoff")
        failureCounts.removeAll()
        unchangedCycles = 0
        pollState = .normal
        Self.clearRateLimitCooldown()
        await executePollCycle()
        scheduleNextPoll()
    }

    // MARK: - Scheduling

    private var currentInterval: TimeInterval {
        let settings = PollingSettings.load()
        let multiplier = PollingSettings.adaptiveMultiplier()
        switch pollState {
        case .active: return settings.activeInterval * multiplier
        case .normal: return settings.normalInterval * multiplier
        case .idle: return settings.idleInterval * multiplier
        case .paused: return .infinity
        case .rateLimited: return rateLimitedInterval
        }
    }

    /// Test-only accessor for `currentInterval`.
    var currentIntervalForTesting: TimeInterval { currentInterval }

    // MARK: - Rate-Limit Persistence

    /// Save the rate-limit expiry so it survives app restarts.
    static func persistRateLimitCooldown(duration: TimeInterval) {
        let expiresAt = Date().addingTimeInterval(duration)
        UserDefaults.standard.set(expiresAt.timeIntervalSince1970, forKey: rateLimitExpiresAtKey)
    }

    /// Seconds remaining on a persisted cooldown, or 0 if expired/absent.
    static func remainingRateLimitCooldown() -> TimeInterval {
        let stored = UserDefaults.standard.double(forKey: rateLimitExpiresAtKey)
        guard stored > 0 else { return 0 }
        return max(Date(timeIntervalSince1970: stored).timeIntervalSinceNow, 0)
    }

    /// Clear the persisted cooldown (rate limit recovered or manual override).
    static func clearRateLimitCooldown() {
        UserDefaults.standard.removeObject(forKey: rateLimitExpiresAtKey)
    }

    // MARK: - Last Poll Persistence

    /// Record that a poll just completed.
    private static func persistLastPollTime() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastPollAtKey)
    }

    /// Seconds since the last successful poll, or nil if never polled.
    static func timeSinceLastPoll() -> TimeInterval? {
        let stored = UserDefaults.standard.double(forKey: lastPollAtKey)
        guard stored > 0 else { return nil }
        return Date().timeIntervalSince(Date(timeIntervalSince1970: stored))
    }

    private func scheduleNextPoll(delay: TimeInterval? = nil) {
        pollTimer?.invalidate()
        pollTimer = nil
        let interval = delay ?? currentInterval
        guard interval.isFinite else { return }

        let actual = max(interval, 1)
        Log.poller.debug("Next poll in \(String(format: "%.0f", actual))s (state: \(self.pollState.rawValue))")

        // Timer must live on the main run loop regardless of which thread schedules it.
        let timer = Timer(timeInterval: actual, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.executePollCycle()
                // Always reschedule — even if the poll errored or state changed.
                // pause() will invalidate the timer if needed.
                if self.pollState != .paused {
                    self.scheduleNextPoll()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func startHistoryTimer() {
        historyTimer?.invalidate()
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.recordSnapshots() }
        }
        RunLoop.main.add(timer, forMode: .common)
        historyTimer = timer
    }

    /// Safety net: if the poll timer dies for any reason (Task cancellation, runloop issue,
    /// unexpected state), the watchdog restarts it. Checks every 60s.
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.pollState != .paused else { return }

            // If no poll timer is active and we're not paused, something went wrong
            if !(self.pollTimer?.isValid ?? false) {
                Log.poller.warning("Watchdog: poll timer is dead — restarting (state: \(self.pollState.rawValue))")
                self.scheduleNextPoll(delay: 5)
                return
            }

            // If it's been way too long since the last poll (3x the expected interval),
            // something is stuck
            if let lastPoll = self.lastPollCycleAt {
                let elapsed = Date().timeIntervalSince(lastPoll)
                let expectedMax = self.currentInterval * 3 + 30 // generous buffer
                if elapsed > expectedMax {
                    Log.poller.warning("Watchdog: last poll was \(String(format: "%.0f", elapsed))s ago (expected max \(String(format: "%.0f", expectedMax))s) — rescheduling")
                    self.scheduleNextPoll(delay: 5)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    // MARK: - Claude Process Detection

    private static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    /// Check if Claude desktop app or CLI is running.
    func detectClaudeRunning() -> Bool {
        // Check Claude.app via NSWorkspace (no shell, very cheap)
        let appRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.claudeDesktopBundleID
        }
        if appRunning { return true }

        // Check Claude CLI via libproc (in-process, no subprocess, no file access prompt)
        return Self.isClaudeCLIRunning()
    }

    /// Scan running processes for a Claude CLI process using libproc APIs.
    /// Unlike pgrep, this doesn't spawn a subprocess or trigger macOS file access prompts.
    private static func isClaudeCLIRunning() -> Bool {
        // Get the number of running processes
        var pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return false }

        // Allocate buffer and fetch all PIDs
        var pids = [pid_t](repeating: 0, count: Int(pidCount))
        pidCount = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard pidCount > 0 else { return false }

        // Check each process for a path containing "claude"
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for i in 0..<Int(pidCount) {
            let pid = pids[i]
            guard pid > 0 else { continue }

            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard pathLen > 0 else { continue }

            let path = String(decoding: pathBuffer[..<Int(pathLen)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // Match claude CLI binary but not this app or Claude.app
            if path.hasSuffix("/claude") || path.contains("/claude-cli/") {
                return true
            }
        }

        return false
    }

    // MARK: - Polling

    private func executePollCycle() async {
        guard pollState != .paused else {
            Log.poller.debug("Poll cycle skipped — paused")
            return
        }

        let accountCount = accountStore.accounts.count
        guard accountCount > 0 else {
            Log.poller.debug("Poll cycle skipped — no accounts")
            return
        }

        // Detect if new accounts were added — reset idle/backoff state
        if accountCount > self.lastKnownAccountCount {
            Log.poller.info("New account(s) detected (\(self.lastKnownAccountCount) → \(accountCount)) — resetting state")
            self.unchangedCycles = 0
            self.failureCounts.removeAll()
            self.backoffSkips.removeAll()
            if self.pollState == .idle {
                self.pollState = .normal
            }
        }
        self.lastKnownAccountCount = accountCount

        // Detect Claude activity to inform idle transition speed
        let wasRunning = claudeIsRunning
        claudeIsRunning = detectClaudeRunning()
        if claudeIsRunning != wasRunning {
            Log.poller.info("Claude running: \(self.claudeIsRunning)")
        }

        Log.poller.info("Poll cycle starting for \(accountCount) account(s)")
        var anyChanged = false
        var hitRateLimit = false
        var retryAfterValue: Double?
        var anyPolled = false

        for account in accountStore.accounts {
            if shouldSkipDueToBackoff(account: account) {
                Log.poller.debug("Skipping \(account.name) due to backoff (failures: \(self.failureCounts[account.id] ?? 0))")
                continue
            }
            anyPolled = true
            let result = await poll(account: account)
            if result.changed { anyChanged = true }
            if result.rateLimited {
                hitRateLimit = true
                retryAfterValue = result.retryAfter
                // Stop polling remaining accounts — API is rate-limiting us
                Log.poller.warning("Rate-limited — skipping remaining accounts")
                break
            }
        }

        // If all accounts were skipped due to backoff, don't count this as
        // an unchanged cycle (which would push us toward idle prematurely)
        if !anyPolled {
            Log.poller.debug("All accounts skipped due to backoff — not updating poll state")
            return
        }

        Self.persistLastPollTime()
        lastPollCycleAt = Date()

        // Record snapshots immediately after polling for maximum data granularity.
        // The dedup guard in UsageHistoryStore prevents redundant entries.
        recordSnapshots()

        widgetWriter.write(accounts: accountStore.accounts)
        momentumProvider?.refresh()
        tokenUsageStore?.refresh()
        apiFileWriter.write(accounts: accountStore.accounts, momentumProvider: momentumProvider, tokenUsageStore: tokenUsageStore)

        let previousState = pollState
        if hitRateLimit {
            PollingSettings.recordRateLimitEvent()
            let cooldown = retryAfterValue ?? Self.defaultRateLimitedInterval
            rateLimitedInterval = max(cooldown, 60) // at least 60s
            pollState = .rateLimited
            Self.persistRateLimitCooldown(duration: rateLimitedInterval)
            Log.poller.warning("Rate-limited — backing off for \(String(format: "%.0f", self.rateLimitedInterval))s")
        } else {
            // Coming out of rate-limit cooldown: resume normal
            if pollState == .rateLimited {
                pollState = .normal
                unchangedCycles = 0
                Self.clearRateLimitCooldown()
            }
            updatePollState(usageChanged: anyChanged)
        }
        if pollState != previousState {
            Log.poller.info("Poll state: \(previousState.rawValue) → \(self.pollState.rawValue)")
        }
    }

    /// Transition the poll state based on whether usage changed this cycle.
    /// Exposed as internal for testing.
    func updatePollState(usageChanged: Bool) {
        if usageChanged {
            unchangedCycles = 0
            pollState = .active
        } else {
            unchangedCycles += 1
            // Go idle faster when Claude isn't running (no point polling frequently)
            let threshold = claudeIsRunning ? Self.idleThreshold : Self.idleThresholdNoClaude
            if unchangedCycles >= threshold {
                pollState = .idle
            } else if pollState == .active {
                pollState = .normal
            }
        }
    }

    private struct PollResult {
        var changed: Bool
        var rateLimited: Bool
        var retryAfter: Double?
    }

    private func poll(account: Account) async -> PollResult {
        do {
            // Proactive refresh: if token expires within 5 minutes, refresh before polling
            if let expiresAt = account.tokenExpiresAt,
               expiresAt.timeIntervalSinceNow < 300 {
                Log.poller.info("[\(account.name)] Token expires in \(String(format: "%.0f", expiresAt.timeIntervalSinceNow))s — proactive refresh")
                if let freshToken = await accountStore.selfRefreshToken(for: account) {
                    Log.poller.info("[\(account.name)] Proactive refresh succeeded")
                    return try await pollWithToken(freshToken, account: account)
                }
                Log.poller.debug("[\(account.name)] Proactive self-refresh failed — continuing with current token")
            }

            guard let token = accountStore.token(for: account), !token.isEmpty else {
                throw APIError.httpError(statusCode: 401, body: "No token stored for account")
            }

            if account.keychainServiceName == nil {
                Log.poller.debug("[\(account.name)] No keychain binding — token refresh on 401 will be limited")
            }

            return try await pollWithToken(token, account: account)
        } catch let error as APIError where error.is401 {
            // Token expired — try self-refresh first, then fall back to keychain re-read
            Log.poller.info("[\(account.name)] 401 — attempting self-refresh")
            if let freshToken = await accountStore.selfRefreshToken(for: account) {
                Log.poller.info("[\(account.name)] Self-refresh succeeded — retrying")
                do {
                    return try await pollWithToken(freshToken, account: account)
                } catch let retryError as APIError where retryError.isRateLimited {
                    let retryAfter: Double?
                    if case .rateLimited(let ra) = retryError { retryAfter = ra } else { retryAfter = nil }
                    Log.poller.warning("[\(account.name)] Retry hit rate limit")
                    return PollResult(changed: false, rateLimited: true, retryAfter: retryAfter)
                } catch {
                    Log.poller.error("[\(account.name)] Retry with self-refreshed token failed: \(error.localizedDescription)")
                    return handlePollError(error, account: account)
                }
            }

            // Fall back to credentials file (prompt-free), then keychain (both prompt-free)
            Log.poller.info("[\(account.name)] Self-refresh unavailable — trying credential refresh")
            if let freshToken = accountStore.refreshTokenFromCredentialsFile(for: account)
                ?? accountStore.refreshTokenFromKeychain(for: account) {
                Log.poller.info("[\(account.name)] Got fresh token — retrying")
                do {
                    let result = try await pollWithToken(freshToken, account: account)
                    await validateTokenOwnership(token: freshToken, account: account)
                    return result
                } catch let retryError as APIError where retryError.isRateLimited {
                    let retryAfter: Double?
                    if case .rateLimited(let ra) = retryError { retryAfter = ra } else { retryAfter = nil }
                    Log.poller.warning("[\(account.name)] Retry hit rate limit")
                    return PollResult(changed: false, rateLimited: true, retryAfter: retryAfter)
                } catch {
                    Log.poller.error("[\(account.name)] Retry with fresh token failed: \(error.localizedDescription)")
                    return handlePollError(error, account: account)
                }
            }
            Log.poller.warning("[\(account.name)] All refresh methods failed — token is expired")
            if account.keychainServiceName == nil {
                return handlePollErrorWithMessage("Token expired. Re-link this account to a keychain entry or re-add with a fresh token.", account: account)
            }
            return handlePollError(error, account: account)
        } catch let error as APIError where error.isRateLimited {
            let retryAfter: Double?
            if case .rateLimited(let ra) = error { retryAfter = ra } else { retryAfter = nil }

            // Before entering cooldown, check if the credentials file has a newer token.
            // Some APIs return 429 for expired tokens, and a re-login may have
            // put a fresh token that would succeed immediately.
            let currentToken = accountStore.token(for: account)
            if let freshToken = accountStore.refreshTokenFromCredentialsFile(for: account),
               freshToken != currentToken {
                Log.poller.info("[\(account.name)] Rate-limited but credentials file has a new token — retrying")
                do {
                    return try await pollWithToken(freshToken, account: account)
                } catch {
                    Log.poller.warning("[\(account.name)] Retry with fresh token also failed: \(error.localizedDescription)")
                }
            }

            let current = failureCounts[account.id] ?? 0
            let newCount = min(current + 1, 5)
            failureCounts[account.id] = newCount
            Log.poller.warning("[\(account.name)] Rate-limited (\(newCount) consecutive), Retry-After: \(retryAfter.map { String(format: "%.0f", $0) } ?? "none")")

            // Re-read from store to avoid overwriting fields changed by refresh steps
            var updated = accountStore.accounts.first { $0.id == account.id } ?? account
            updated.lastError = error.localizedDescription
            accountStore.updateAccount(updated)

            return PollResult(changed: false, rateLimited: true, retryAfter: retryAfter)
        } catch {
            return handlePollError(error, account: account)
        }
    }

    /// Validate that a refreshed token still belongs to this account by checking the profile email.
    private func validateTokenOwnership(token: String, account: Account) async {
        guard let expectedEmail = account.profile?.email else { return }

        do {
            let profile = try await apiClient.fetchProfile(token: token)
            if profile.account.email != expectedEmail {
                Log.poller.error("[\(account.name, privacy: .private)] Token email mismatch — clearing token")
                // Re-read from store to avoid overwriting usage data saved by pollWithToken
                var updated = accountStore.accounts.first { $0.id == account.id } ?? account
                updated.lastError = "Token belongs to \(profile.account.email), not \(expectedEmail). Re-link this account to the correct keychain entry."
                // Clear the bad token so we don't keep using it
                accountStore.updateToken("", for: account)
                accountStore.updateAccount(updated)
            }
        } catch {
            // Don't fail the poll over a validation check — just log it
            Log.poller.warning("[\(account.name)] Could not validate token ownership: \(error.localizedDescription)")
        }
    }

    /// Clamp utilization to 0...100 at the API boundary. Guards against NaN,
    /// negative values, or >100 responses that would corrupt downstream calculations.
    private static func clampUtilization(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 100)
    }

    private func pollWithToken(_ token: String, account: Account) async throws -> PollResult {
        let usage = try await apiClient.fetchUsage(token: token)

        // Re-read from the store to pick up any changes made by selfRefreshToken
        // (e.g. tokenExpiresAt) that would otherwise be overwritten by the stale copy.
        var updated = accountStore.accounts.first { $0.id == account.id } ?? account
        updated.fiveHour = UsageWindow(
            utilization: Self.clampUtilization(usage.fiveHour.utilization),
            resetsAt: DateFormatting.parseISO8601(usage.fiveHour.resetsAt) ?? .now,
            duration: UsageWindow.fiveHourDuration
        )
        updated.sevenDay = UsageWindow(
            utilization: Self.clampUtilization(usage.sevenDay.utilization),
            resetsAt: DateFormatting.parseISO8601(usage.sevenDay.resetsAt) ?? .now,
            duration: UsageWindow.sevenDayDuration
        )
        updated.lastUpdated = .now
        updated.lastError = nil

        failureCounts[account.id] = 0

        // Detect whether utilization changed
        let newUtilization = usage.fiveHour.utilization
        let previous = previousUtilizations[account.id]
        let changed = previous.map { abs(newUtilization - $0) > 0.001 } ?? false
        previousUtilizations[account.id] = newUtilization

        if changed {
            Log.poller.info("[\(account.name)] Usage changed: \(String(format: "%.1f%%", previous ?? 0)) → \(String(format: "%.1f%%", newUtilization))")
        } else {
            Log.poller.debug("[\(account.name)] Usage unchanged at \(String(format: "%.1f%%", newUtilization))")
        }

        accountStore.updateAccount(updated)

        return PollResult(changed: changed, rateLimited: false, retryAfter: nil)
    }

    private func handlePollError(_ error: any Error, account: Account) -> PollResult {
        handlePollErrorWithMessage(error.localizedDescription, account: account)
    }

    private func handlePollErrorWithMessage(_ message: String, account: Account) -> PollResult {
        let current = failureCounts[account.id] ?? 0
        let newCount = min(current + 1, 5)
        failureCounts[account.id] = newCount
        Log.poller.error("[\(account.name)] Poll failed (\(newCount) consecutive): \(message)")

        // Re-read from store to avoid overwriting fields changed by refresh/poll steps
        var updated = accountStore.accounts.first { $0.id == account.id } ?? account
        updated.lastError = message
        accountStore.updateAccount(updated)

        return PollResult(changed: false, rateLimited: false, retryAfter: nil)
    }

    /// Exponential backoff: skip this tick if the account has failed recently.
    /// Uses a skip counter that counts down — when it reaches 0 the account is retried.
    private var backoffSkips: [UUID: Int] = [:]

    private func shouldSkipDueToBackoff(account: Account) -> Bool {
        guard let failures = failureCounts[account.id], failures > 0 else {
            backoffSkips.removeValue(forKey: account.id)
            return false
        }
        // Initialize skip counter on first check after a failure
        if backoffSkips[account.id] == nil {
            // Skip 1 cycle for 1 failure, 2 for 2, etc. (capped at 5)
            backoffSkips[account.id] = min(failures, 5)
        }
        let remaining = backoffSkips[account.id] ?? 0
        if remaining <= 0 {
            backoffSkips[account.id] = nil
            return false
        }
        backoffSkips[account.id] = remaining - 1
        return true
    }

    // MARK: - System Events

    private func observeSystemEvents() {
        // Remove any existing observers to prevent duplicates if start() is called twice
        removeSystemObservers()

        let ws = NSWorkspace.shared.notificationCenter
        let dc = DistributedNotificationCenter.default()

        // Screen lock/unlock — Claude Code keeps running, so just go idle (no gap)
        observers.append(
            dc.addObserver(
                forName: .init("com.apple.screenIsLocked"),
                object: nil, queue: .main
            ) { [weak self] _ in
                Log.poller.info("Screen locked — switching to idle polling")
                self?.enterScreenOff()
            }
        )
        observers.append(
            dc.addObserver(
                forName: .init("com.apple.screenIsUnlocked"),
                object: nil, queue: .main
            ) { [weak self] _ in
                Log.poller.info("Screen unlocked — resuming normal polling")
                self?.exitScreenOff()
            }
        )

        // Display sleep/wake — same as screen lock, Claude Code keeps running
        observers.append(
            ws.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Log.poller.info("Display sleeping — switching to idle polling")
                self?.enterScreenOff()
            }
        )
        observers.append(
            ws.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Log.poller.info("Display woke — resuming normal polling")
                self?.exitScreenOff()
            }
        )

        // System sleep/wake — the machine is actually sleeping, record a gap
        observers.append(
            ws.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Log.poller.info("System sleeping — pausing (will record gap)")
                self?.pause(forSystemSleep: true)
            }
        )
        observers.append(
            ws.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Log.poller.info("System woke — resuming")
                self?.resume()
            }
        )

        Log.poller.info("System event observers registered (lock/unlock, display sleep/wake, system sleep/wake)")
    }

    private func removeSystemObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        let dc = DistributedNotificationCenter.default()
        for observer in observers {
            ws.removeObserver(observer)
            dc.removeObserver(observer)
        }
        observers.removeAll()
        Log.poller.debug("System event observers removed")
    }

    /// Screen locked or display sleeping — Claude Code still runs, so just slow down polling.
    /// No gap is recorded.
    private func enterScreenOff() {
        guard pollState != .paused else { return }
        pollState = .idle
        // Reschedule at idle interval
        scheduleNextPoll()
    }

    /// Screen unlocked or display woke — go back to normal polling cadence.
    private func exitScreenOff() {
        guard pollState != .paused else { return }
        unchangedCycles = 0
        pollState = .normal
        scheduleNextPoll(delay: 0)
    }

    private func pause(forSystemSleep: Bool = false) {
        guard pollState != .paused else { return }
        pausedAt = Date()
        pausedForSystemSleep = forSystemSleep
        pollState = .paused
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func resume() {
        guard pollState == .paused else { return }
        let wasSystemSleep = pausedForSystemSleep
        if pausedForSystemSleep, let start = pausedAt {
            let gap = MonitoringGap(start: start, end: Date())
            historyStore.addGap(gap)
            historyStore.saveGaps()
            Log.poller.info("Recorded monitoring gap: \(String(format: "%.0f", gap.end.timeIntervalSince(gap.start)))s")
        }
        pausedAt = nil
        pausedForSystemSleep = false

        // Check if a rate-limit cooldown is still active
        let remaining = Self.remainingRateLimitCooldown()
        if remaining > 0 {
            pollState = .rateLimited
            rateLimitedInterval = remaining
            Log.poller.info("Resuming into rate-limit cooldown — \(String(format: "%.0f", remaining))s remaining")
            scheduleNextPoll(delay: remaining)
        } else {
            Self.clearRateLimitCooldown()
            pollState = .normal
            unchangedCycles = 0
            // Short delay after system sleep to let the network settle (WiFi reconnect, VPN, etc.)
            // Avoids a doomed first poll that increments failure counts and enters backoff.
            scheduleNextPoll(delay: wasSystemSleep ? 5 : 0)
        }
    }

    // MARK: - History

    private func recordSnapshots() {
        var recorded = 0
        for account in accountStore.accounts {
            guard let fiveHour = account.fiveHour, let sevenDay = account.sevenDay else { continue }
            let snapshot = UsageSnapshot(
                accountID: account.id,
                fiveHourUtilization: fiveHour.utilization,
                sevenDayUtilization: sevenDay.utilization
            )
            historyStore.addSnapshot(snapshot)
            recorded += 1
        }
        historyStore.save()
        Log.history.debug("Recorded \(recorded) snapshot(s), total: \(self.historyStore.snapshots.count)")
    }
}
