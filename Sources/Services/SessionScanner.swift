import Foundation

/// Reads Claude Code session JSONL files from `~/.claude/projects/` to extract
/// per-message token usage data. Tracks byte offsets per file to only read new data.
/// Offsets persist across app launches to avoid double-counting.
@Observable
@MainActor final class SessionScanner {
    private(set) var isScanning = false

    private let defaultProjectsDir: URL
    /// Additional project directories from accounts with custom `.claude` config dirs.
    private(set) var extraProjectsDirs: [URL] = []
    private let offsetsFileURL: URL
    /// Track the byte offset we've already read for each file (incremental reads).
    private var fileOffsets: [String: UInt64] = [:]
    /// Cached session summaries from previous scans — avoids re-reading entire files.
    private var cachedSessions: [String: SessionSummary] = [:]
    /// Byte offsets for session scanning (separate from token scanning offsets).
    private var sessionOffsets: [String: UInt64] = [:]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// All project directories to scan (default + extras, deduplicated).
    private var allProjectsDirs: [URL] {
        var dirs = [defaultProjectsDir]
        let defaultPath = defaultProjectsDir.standardizedFileURL.path
        for dir in extraProjectsDirs {
            if dir.standardizedFileURL.path != defaultPath {
                dirs.append(dir)
            }
        }
        return dirs
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.defaultProjectsDir = home.appendingPathComponent(".claude/projects", isDirectory: true)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Clusage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.offsetsFileURL = dir.appendingPathComponent("scanner-offsets.json")

        loadOffsets()
    }

    /// Update the set of extra project directories from account configurations.
    func updateExtraDirectories(from accounts: [Account]) {
        extraProjectsDirs = accounts.compactMap { account in
            guard let dir = account.claudeConfigDir else { return nil }
            let expanded = NSString(string: dir).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        }
    }

    /// Scan all session JSONL files and return new token events since last scan.
    /// Each event is (model, date string, TokenUsage, isNewSession).
    func scanForNewUsage() -> [(model: String, date: String, usage: TokenUsage, newSession: Bool)] {
        isScanning = true
        defer {
            isScanning = false
            saveOffsets()
        }

        let fm = FileManager.default
        var results: [(model: String, date: String, usage: TokenUsage, newSession: Bool)] = []

        let jsonlFiles = findJSONLFiles()
        guard !jsonlFiles.isEmpty else { return [] }

        for fileURL in jsonlFiles {
            let path = fileURL.path

            // Quick size check — skip if file hasn't grown past our offset
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let fileSize = attrs[.size] as? UInt64 else { continue }

            let offset = fileOffsets[path] ?? 0
            guard fileSize > offset else { continue }

            let isNewFile = fileOffsets[path] == nil

            guard let fileHandle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? fileHandle.close() }

            if offset > 0 {
                fileHandle.seek(toFileOffset: offset)
            }

            let data = fileHandle.readDataToEndOfFile()
            let newOffset = fileHandle.offsetInFile
            fileOffsets[path] = newOffset

            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { continue }

            var firstForFile = isNewFile
            for line in text.components(separatedBy: "\n") where !line.isEmpty {
                guard let lineData = line.data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      entry["type"] as? String == "assistant",
                      let message = entry["message"] as? [String: Any],
                      let usageDict = message["usage"] as? [String: Any],
                      let model = message["model"] as? String,
                      // Only count final responses — streaming snapshots have stop_reason: null
                      // and duplicate the same usage data multiple times per turn
                      message["stop_reason"] is String else { continue }

                let inputTokens = usageDict["input_tokens"] as? Int ?? 0
                let outputTokens = usageDict["output_tokens"] as? Int ?? 0
                let cacheRead = usageDict["cache_read_input_tokens"] as? Int ?? 0
                let cacheCreate = usageDict["cache_creation_input_tokens"] as? Int ?? 0

                guard inputTokens + outputTokens + cacheRead + cacheCreate > 0 else { continue }

                let timestamp = entry["timestamp"] as? String ?? ""
                let date = Self.extractDate(from: timestamp)

                let usage = TokenUsage(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadInputTokens: cacheRead,
                    cacheCreationInputTokens: cacheCreate
                )

                results.append((model: model, date: date, usage: usage, newSession: firstForFile))
                firstForFile = false
            }
        }

        return results
    }

    /// Build session summaries by reading session JSONL files incrementally.
    /// Only reads top-level session files (not subagents) since subagents are part
    /// of a parent session. Uses cached summaries and only reads new bytes.
    func scanSessions(since cutoffDate: String) -> [SessionSummary] {
        let fm = FileManager.default

        // Track which sessions we see this scan to prune stale cache entries
        var seenSessionIDs = Set<String>()

        for projectsDir in allProjectsDirs {
        guard fm.fileExists(atPath: projectsDir.path) else { continue }
        guard let projectDirs = fm.contentsOfDirectory(atPath: projectsDir.path, includingHidden: false) else { continue }

        for projectName in projectDirs {
            let projectDir = projectsDir.appendingPathComponent(projectName)
            guard let contents = fm.contentsOfDirectory(atPath: projectDir.path, includingHidden: false) else { continue }
            for item in contents where item.hasSuffix(".jsonl") {
                let fileURL = projectDir.appendingPathComponent(item)
                let path = fileURL.path
                let sessionID = String(item.dropLast(6)) // strip .jsonl
                seenSessionIDs.insert(sessionID)

                // Skip if file hasn't grown past our session offset
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let fileSize = attrs[.size] as? UInt64 else { continue }
                let offset = sessionOffsets[path] ?? 0
                guard fileSize > offset || cachedSessions[sessionID] == nil else { continue }

                // Read only new bytes (or full file if first scan for this session)
                let needsFullRead = cachedSessions[sessionID] == nil
                let readOffset: UInt64 = needsFullRead ? 0 : offset

                guard let fileHandle = FileHandle(forReadingAtPath: path) else { continue }
                defer { try? fileHandle.close() }

                if readOffset > 0 { fileHandle.seek(toFileOffset: readOffset) }
                let data = fileHandle.readDataToEndOfFile()
                sessionOffsets[path] = fileHandle.offsetInFile

                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { continue }

                let newMessages = Self.parseSessionMessages(from: text)
                guard !newMessages.isEmpty || cachedSessions[sessionID] != nil else { continue }

                if needsFullRead {
                    // Build summary from scratch
                    guard !newMessages.isEmpty else { continue }
                    if let summary = Self.buildSessionSummary(id: sessionID, messages: newMessages) {
                        if summary.date >= cutoffDate {
                            cachedSessions[sessionID] = summary
                        }
                    }
                } else if !newMessages.isEmpty, var existing = cachedSessions[sessionID] {
                    // Incrementally update existing summary with new messages
                    for msg in newMessages {
                        existing.messageCount += 1
                        existing.costUSD += msg.cost
                        existing.endContextTokens = msg.context
                        existing.peakContextTokens = max(existing.peakContextTokens, msg.context)
                        existing.totalOutputTokens += msg.output
                    }
                    if let last = newMessages.last {
                        if let firstTimestamp = Self.parseISO8601(existing.date + "T00:00:00Z"),
                           let lastTimestamp = Self.parseISO8601(last.timestamp) {
                            existing.durationSeconds = lastTimestamp.timeIntervalSince(firstTimestamp)
                        }
                    }
                    cachedSessions[sessionID] = existing
                }
            }
        }
        } // end for projectsDir in allProjectsDirs

        // Prune cache entries for deleted files
        cachedSessions = cachedSessions.filter { seenSessionIDs.contains($0.key) }

        return cachedSessions.values
            .filter { $0.date >= cutoffDate }
            .sorted { $0.date > $1.date }
    }

    private typealias ParsedMessage = (model: String, date: String, timestamp: String, context: Int, output: Int, cost: Double)

    private static func parseSessionMessages(from text: String) -> [ParsedMessage] {
        var messages: [ParsedMessage] = []
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let usageDict = message["usage"] as? [String: Any],
                  let model = message["model"] as? String,
                  message["stop_reason"] is String else { continue }

            let input = usageDict["input_tokens"] as? Int ?? 0
            let output = usageDict["output_tokens"] as? Int ?? 0
            let cacheRead = usageDict["cache_read_input_tokens"] as? Int ?? 0
            let cacheWrite = usageDict["cache_creation_input_tokens"] as? Int ?? 0
            guard input + output + cacheRead + cacheWrite > 0 else { continue }

            let timestamp = entry["timestamp"] as? String ?? ""
            let date = extractDate(from: timestamp)
            let context = input + cacheRead + cacheWrite

            let price = TokenPricing.price(for: model)
            let tokens = ModelTokens(
                inputTokens: input, outputTokens: output,
                cacheReadInputTokens: cacheRead, cacheCreationInputTokens: cacheWrite
            )
            let cost = price.cost(for: tokens)
            messages.append((model: model, date: date, timestamp: timestamp, context: context, output: output, cost: cost))
        }
        return messages
    }

    private static func buildSessionSummary(id: String, messages: [ParsedMessage]) -> SessionSummary? {
        guard let first = messages.first, let last = messages.last else { return nil }

        var modelCounts: [String: Int] = [:]
        for m in messages { modelCounts[m.model, default: 0] += 1 }
        let primaryModel = modelCounts.max(by: { $0.value < $1.value })?.key ?? "unknown"

        var duration: Double?
        if messages.count >= 2,
           let firstDate = parseISO8601(first.timestamp),
           let lastDate = parseISO8601(last.timestamp) {
            duration = lastDate.timeIntervalSince(firstDate)
        }

        return SessionSummary(
            id: id,
            date: first.date,
            messageCount: messages.count,
            costUSD: messages.reduce(0) { $0 + $1.cost },
            startContextTokens: first.context,
            endContextTokens: last.context,
            peakContextTokens: messages.map(\.context).max() ?? 0,
            totalOutputTokens: messages.reduce(0) { $0 + $1.output },
            primaryModel: primaryModel,
            durationSeconds: duration
        )
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseISO8601(_ string: String) -> Date? {
        iso8601Formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    /// Reset tracking state, forcing a full re-scan on next call.
    func reset() {
        fileOffsets.removeAll()
        saveOffsets()
    }

    func saveOffsets() {
        guard let data = try? JSONEncoder().encode(fileOffsets) else { return }
        try? data.write(to: offsetsFileURL, options: .atomic)
    }

    // MARK: - Private

    private func loadOffsets() {
        guard let data = try? Data(contentsOf: offsetsFileURL),
              let decoded = try? JSONDecoder().decode([String: UInt64].self, from: data) else { return }
        fileOffsets = decoded
        // Prune offsets for files that no longer exist
        let fm = FileManager.default
        let before = fileOffsets.count
        fileOffsets = fileOffsets.filter { fm.fileExists(atPath: $0.key) }
        if fileOffsets.count < before {
            Log.tokens.info("Pruned \(before - self.fileOffsets.count) stale scanner offset(s)")
        }
    }

    private func findJSONLFiles() -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []

        for projectsDir in allProjectsDirs {
        guard let projectEnumerator = fm.contentsOfDirectory(atPath: projectsDir.path,
                                                              includingHidden: false) else { continue }

        for projectName in projectEnumerator {
            let projectDir = projectsDir.appendingPathComponent(projectName)
            guard let contents = fm.contentsOfDirectory(atPath: projectDir.path, includingHidden: false) else { continue }
            for item in contents {
                let itemURL = projectDir.appendingPathComponent(item)
                if item.hasSuffix(".jsonl") {
                    files.append(itemURL)
                } else {
                    // Check for subagents directory
                    let subagentsDir = itemURL.appendingPathComponent("subagents")
                    if let subFiles = fm.contentsOfDirectory(atPath: subagentsDir.path, includingHidden: false) {
                        for sub in subFiles where sub.hasSuffix(".jsonl") {
                            files.append(subagentsDir.appendingPathComponent(sub))
                        }
                    }
                }
            }
        }
        } // end for projectsDir in allProjectsDirs
        return files
    }

    /// Extract "yyyy-MM-dd" from an ISO 8601 timestamp string, or fall back to today.
    private static func extractDate(from isoTimestamp: String) -> String {
        if isoTimestamp.count >= 10, isoTimestamp[isoTimestamp.index(isoTimestamp.startIndex, offsetBy: 4)] == "-" {
            return String(isoTimestamp.prefix(10))
        }
        return dateFormatter.string(from: Date())
    }
}

// MARK: - FileManager helper

private extension FileManager {
    func contentsOfDirectory(atPath path: String, includingHidden: Bool) -> [String]? {
        try? contentsOfDirectory(atPath: path).filter { includingHidden || !$0.hasPrefix(".") }
    }
}
