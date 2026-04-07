import Foundation

/// Persists daily token usage summaries aggregated from Claude Code session files.
/// Provides rolling windows (today, 5-hour, 7-day) for cost and token insights.
@Observable
@MainActor final class TokenUsageStore {
    private(set) var dailySummaries: [TokenUsageSummary] = []
    private(set) var sessionSummaries: [SessionSummary] = []

    private let fileURL: URL
    private let sessionsFileURL: URL
    private let scanner: SessionScanner

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(scanner: SessionScanner = SessionScanner()) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("Clusage", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("token-usage.json")
        self.sessionsFileURL = directory.appendingPathComponent("session-summaries.json")
        self.scanner = scanner
        load()
        loadSessions()
    }

    /// Scan for new session data and merge into daily summaries.
    func refresh() {
        let events = scanner.scanForNewUsage()
        guard !events.isEmpty else { return }

        var newMessages = 0
        var newSessions = 0

        for event in events {
            var summary = dailySummaries.first { $0.date == event.date }
                ?? TokenUsageSummary(date: event.date)

            if dailySummaries.contains(where: { $0.date == event.date }) {
                dailySummaries.removeAll { $0.date == event.date }
            }

            var modelTokens = summary.models[event.model] ?? ModelTokens()
            modelTokens.add(event.usage)
            summary.models[event.model] = modelTokens
            summary.messageCount += 1
            newMessages += 1
            if event.newSession {
                summary.sessionCount += 1
                newSessions += 1
            }
            dailySummaries.append(summary)
        }

        // Sort by date
        dailySummaries.sort { $0.date < $1.date }

        // Prune older than 30 days
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let cutoffStr = Self.dateFormatter.string(from: cutoff)
        dailySummaries.removeAll { $0.date < cutoffStr }

        save()
        Log.tokens.info("Scanned \(newMessages) message(s) from \(newSessions) new session(s)")
    }

    /// Full re-scan: clears cached state and re-reads all session files.
    func fullRescan() {
        dailySummaries.removeAll()
        sessionSummaries.removeAll()
        scanner.reset()
        refresh()
        refreshSessions()
    }

    /// Rebuild session summaries from JSONL files for the last 30 days.
    func refreshSessions() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let cutoffStr = Self.dateFormatter.string(from: cutoff)
        sessionSummaries = scanner.scanSessions(since: cutoffStr)

        // Prune
        sessionSummaries.removeAll { $0.date < cutoffStr }
        saveSessions()
        Log.tokens.info("Scanned \(self.sessionSummaries.count) session summary(ies)")
    }

    // MARK: - Session Queries

    /// Average cost per session over the last N days.
    var averageSessionCost: Double {
        guard !sessionSummaries.isEmpty else { return 0 }
        return sessionSummaries.reduce(0) { $0 + $1.costUSD } / Double(sessionSummaries.count)
    }

    /// Average messages per session.
    var averageMessagesPerSession: Double {
        guard !sessionSummaries.isEmpty else { return 0 }
        return Double(sessionSummaries.reduce(0) { $0 + $1.messageCount }) / Double(sessionSummaries.count)
    }

    /// Average context compounding ratio across sessions.
    var averageCompoundingRatio: Double {
        let valid = sessionSummaries.filter { $0.startContextTokens > 0 }
        guard !valid.isEmpty else { return 0 }
        return valid.reduce(0) { $0 + $1.compoundingRatio } / Double(valid.count)
    }

    /// Sessions for a specific date.
    func sessions(for date: String) -> [SessionSummary] {
        sessionSummaries.filter { $0.date == date }
    }

    /// Sessions from the last N days, sorted newest first.
    func recentSessions(days n: Int) -> [SessionSummary] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -(n - 1), to: Date())!
        let cutoffStr = Self.dateFormatter.string(from: cutoff)
        return sessionSummaries.filter { $0.date >= cutoffStr }
    }

    /// The most expensive sessions, limited to N.
    func mostExpensiveSessions(limit: Int = 5) -> [SessionSummary] {
        Array(sessionSummaries.sorted { $0.costUSD > $1.costUSD }.prefix(limit))
    }

    // MARK: - Queries

    /// Today's summary.
    var today: TokenUsageSummary? {
        let todayStr = Self.dateFormatter.string(from: Date())
        return dailySummaries.first { $0.date == todayStr }
    }

    /// Total cost for the last N days (including today).
    func cost(lastDays n: Int) -> Double {
        let cutoff = Calendar.current.date(byAdding: .day, value: -(n - 1), to: Date())!
        let cutoffStr = Self.dateFormatter.string(from: cutoff)
        return dailySummaries
            .filter { $0.date >= cutoffStr }
            .reduce(0) { $0 + costForSummary($1) }
    }

    /// Daily average cost over the last N days.
    func averageDailyCost(lastDays n: Int) -> Double {
        cost(lastDays: n) / Double(n)
    }

    /// Total tokens for the last N days.
    func tokens(lastDays n: Int) -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -(n - 1), to: Date())!
        let cutoffStr = Self.dateFormatter.string(from: cutoff)
        return dailySummaries
            .filter { $0.date >= cutoffStr }
            .reduce(0) { $0 + $1.totalTokens }
    }

    /// Summaries for the last N days, filled with empty days where no usage occurred.
    func recentSummaries(days n: Int) -> [TokenUsageSummary] {
        var result: [TokenUsageSummary] = []
        let calendar = Calendar.current
        for i in stride(from: n - 1, through: 0, by: -1) {
            let date = calendar.date(byAdding: .day, value: -i, to: Date())!
            let dateStr = Self.dateFormatter.string(from: date)
            if let existing = dailySummaries.first(where: { $0.date == dateStr }) {
                result.append(existing)
            } else {
                result.append(TokenUsageSummary(date: dateStr))
            }
        }
        return result
    }

    /// Calculate cost for a summary using model-specific pricing.
    func costForSummary(_ summary: TokenUsageSummary) -> Double {
        summary.models.reduce(0) { total, pair in
            total + TokenPricing.cost(model: pair.key, tokens: pair.value)
        }
    }

    // MARK: - Persistence

    func save() {
        guard let data = try? JSONEncoder().encode(dailySummaries) else { return }
        try? data.write(to: fileURL, options: .atomic)
        scanner.saveOffsets()
    }

    func saveSessions() {
        guard let data = try? JSONEncoder().encode(sessionSummaries) else { return }
        try? data.write(to: sessionsFileURL, options: .atomic)
    }

    private func loadSessions() {
        guard let data = try? Data(contentsOf: sessionsFileURL),
              let decoded = try? JSONDecoder().decode([SessionSummary].self, from: data) else { return }
        sessionSummaries = decoded
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let cutoffStr = Self.dateFormatter.string(from: cutoff)
        let before = sessionSummaries.count
        sessionSummaries.removeAll { $0.date < cutoffStr }
        if sessionSummaries.count < before {
            Log.tokens.info("Pruned \(before - self.sessionSummaries.count) stale session summary(ies)")
            saveSessions()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        dailySummaries = (try? JSONDecoder().decode([TokenUsageSummary].self, from: data)) ?? []
        // Prune old data
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let cutoffStr = Self.dateFormatter.string(from: cutoff)
        let before = dailySummaries.count
        dailySummaries.removeAll { $0.date < cutoffStr }
        if dailySummaries.count < before {
            Log.tokens.info("Pruned \(before - self.dailySummaries.count) stale token summary(ies)")
            save()
        }
    }
}
