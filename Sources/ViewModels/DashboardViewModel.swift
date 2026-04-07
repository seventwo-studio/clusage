import Foundation

enum SidebarItem: Hashable {
    case account(UUID)
    case disclaimer
    case accounts
    case samples
    case schedule
    case settings
}

@MainActor @Observable
final class DashboardViewModel {
    let accountStore: AccountStore
    let historyStore: UsageHistoryStore
    let streakStore: StreakStore?
    let momentumProvider: MomentumProvider?
    let poller: UsagePoller?
    let tokenUsageStore: TokenUsageStore?
    var selectedItem: SidebarItem?

    init(accountStore: AccountStore, historyStore: UsageHistoryStore, streakStore: StreakStore? = nil, momentumProvider: MomentumProvider? = nil, poller: UsagePoller? = nil, tokenUsageStore: TokenUsageStore? = nil) {
        self.accountStore = accountStore
        self.historyStore = historyStore
        self.streakStore = streakStore
        self.momentumProvider = momentumProvider
        self.poller = poller
        self.tokenUsageStore = tokenUsageStore
    }

    var accounts: [Account] {
        accountStore.accounts
    }

    var selectedAccount: Account? {
        guard case .account(let id) = selectedItem else {
            if selectedItem == nil { return accounts.first }
            return nil
        }
        return accounts.first { $0.id == id }
    }

    func snapshots(for account: Account) -> [UsageSnapshot] {
        historyStore.snapshots(for: account.id)
    }

    var gaps: [MonitoringGap] {
        historyStore.gaps
    }

    func momentum(for account: Account) -> MomentumCalculation? {
        momentumProvider?.momentum(for: account.id)
    }

    func burstSummary(for account: Account) -> BurstSummary? {
        momentumProvider?.burstSummary(for: account.id)
    }

    func streak(for account: Account) -> UsageStreak? {
        momentumProvider?.streak(for: account.id)
    }

    func projection(for account: Account) -> WindowProjection? {
        momentumProvider?.projection(for: account.id)
    }

    func dailyTarget(for account: Account) -> BudgetEngine.DailyTarget? {
        momentumProvider?.dailyTarget(for: account.id)
    }

    var pollState: UsagePoller.PollState? {
        poller?.pollState
    }

    var rateLimitSecondsRemaining: TimeInterval? {
        guard poller?.pollState == .rateLimited else { return nil }
        let remaining = UsagePoller.remainingRateLimitCooldown()
        return remaining > 0 ? remaining : nil
    }

    // MARK: - Schedule Overrides

    func hasScheduleOverride(for account: Account) -> Bool {
        account.usagePlan.hasOverride(for: .now)
    }

    /// Apply a schedule override for today on a specific account, or clear it if `slot` is nil.
    func applyScheduleOverride(_ slot: DaySlot?, for account: Account) {
        var updated = account
        if let slot {
            updated.usagePlan.setOverride(slot, for: .now)
        } else {
            updated.usagePlan.clearOverride(for: .now)
        }
        updated.usagePlan.pruneOldOverrides()
        accountStore.updateAccount(updated)
        momentumProvider?.refresh()
    }
}
