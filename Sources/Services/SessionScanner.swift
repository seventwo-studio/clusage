import Foundation

/// Reads Claude Code session JSONL files from `~/.claude/projects/` to extract
/// per-message token usage data. Tracks byte offsets per file to only read new data.
/// Offsets persist across app launches to avoid double-counting.
@Observable
@MainActor final class SessionScanner {
    private(set) var isScanning = false

    private let projectsDir: URL
    private let offsetsFileURL: URL
    /// Track the byte offset we've already read for each file (incremental reads).
    private var fileOffsets: [String: UInt64] = [:]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.projectsDir = home.appendingPathComponent(".claude/projects", isDirectory: true)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Clusage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.offsetsFileURL = dir.appendingPathComponent("scanner-offsets.json")

        loadOffsets()
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
        guard fm.fileExists(atPath: projectsDir.path) else {
            Log.tokens.debug("Projects directory not found: \(self.projectsDir.path)")
            return []
        }

        var results: [(model: String, date: String, usage: TokenUsage, newSession: Bool)] = []

        let jsonlFiles = findJSONLFiles()

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
        guard let projectEnumerator = fm.contentsOfDirectory(atPath: projectsDir.path,
                                                              includingHidden: false) else { return [] }

        var files: [URL] = []
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
