import Foundation
import Security

/// A Claude Code credential found in the macOS Keychain or credentials file.
struct DetectedCredential: Identifiable, Sendable {
    let id = UUID()
    let serviceName: String
    let accessToken: String
    /// OAuth refresh token (if available from the credential source).
    var refreshToken: String?
    /// When the access token expires (if known).
    var expiresAt: Date?
    /// Email fetched from the profile API (populated after detection).
    var email: String?

    /// Human-readable label derived from metadata.
    var label: String {
        if let email { return email }
        // Strip the "Claude Code-credentials-" prefix to show just the short ID
        if serviceName.hasPrefix("Claude Code-credentials-") {
            return "Claude Code (\(serviceName.dropFirst("Claude Code-credentials-".count)))"
        }
        return serviceName
    }

    /// Where this credential was sourced from (Keychain vs credentials file).
    var sourceDescription: String {
        if serviceName == CredentialsFileReader.serviceName {
            return "Credentials file"
        }
        return "Keychain"
    }
}

/// Handles Claude Code credential detection from the system keychain.
/// Uses `/usr/bin/security` CLI for prompt-free reads — the Apple-signed binary matches
/// the `apple-tool:` partition_id, so it never triggers macOS password dialogs.
/// Token storage for Clusage accounts uses the macOS Keychain via the Security framework.
enum KeychainManager {

    // MARK: - Claude Code Detection

    /// Find all Claude Code credential entries via the security CLI (prompt-free).
    static func detectAllClaudeCodeCredentials() -> [DetectedCredential] {
        Log.keychain.debug("Searching for Claude Code keychain items via security CLI")

        let serviceNames = findClaudeCodeServiceNames()
        guard !serviceNames.isEmpty else {
            Log.keychain.info("No Claude Code credentials found")
            return []
        }

        Log.keychain.debug("Found \(serviceNames.count) Claude Code service name(s)")

        var credentials: [DetectedCredential] = []
        for serviceName in serviceNames {
            if let cred = fetchClaudeCodeCredential(serviceName: serviceName) {
                credentials.append(cred)
            }
        }

        Log.keychain.info("Found \(credentials.count) Claude Code credential(s)")
        return credentials
    }

    /// Find all keychain service names containing "Claude Code-credentials".
    /// Uses `security dump-keychain` for discovery — it reads metadata without triggering
    /// any access prompts. The actual credential data is read later via `security find-generic-password`.
    private static func findClaudeCodeServiceNames() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["dump-keychain"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.keychain.warning("Failed to run security CLI: \(error.localizedDescription)")
            return []
        }

        // Read pipe data on a background thread to avoid a deadlock: dump-keychain can
        // produce output larger than the ~64 KB pipe buffer, so the process blocks on
        // write if nobody is draining the pipe. Reading concurrently lets the process
        // finish while we also enforce a timeout.
        var data = Data()
        let readQueue = DispatchQueue(label: "clusage.keychain.read")
        readQueue.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
        }

        // 5-second timeout guard — dump-keychain can hang on corrupted or locked keychains
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            Log.keychain.warning("security dump-keychain timed out")
            return []
        }

        // Process exited — wait briefly for the read to finish draining the pipe
        readQueue.sync {}

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var serviceNames = Set<String>()
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("0x00000007") && trimmed.contains("Claude Code-credentials") {
                if let start = trimmed.range(of: "=\""),
                   let end = trimmed.range(of: "\"", range: start.upperBound..<trimmed.endIndex) {
                    let name = String(trimmed[start.upperBound..<end.lowerBound])
                    serviceNames.insert(name)
                }
            }
        }

        return Array(serviceNames)
    }

    /// Fetch a single Claude Code credential by service name via `/usr/bin/security`.
    /// The Apple-signed binary matches `apple-tool:` partition_id — never triggers password prompts,
    /// even after Claude Code rotates its OAuth token.
    static func fetchClaudeCodeCredential(serviceName: String) -> DetectedCredential? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", serviceName, "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.keychain.warning("Failed to run security CLI for '\(serviceName)': \(error.localizedDescription)")
            return nil
        }

        // 2-second timeout guard against corrupted keychain locks
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            Log.keychain.warning("security CLI timed out for '\(serviceName)'")
            return nil
        }

        let exitCode = process.terminationStatus
        guard exitCode == 0 else {
            if exitCode == 44 {
                Log.keychain.debug("Keychain item '\(serviceName)' not found (exit 44)")
            } else {
                Log.keychain.warning("security CLI failed for '\(serviceName)': exit code \(exitCode)")
            }
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return parseClaudeCodeCredential(data: data, serviceName: serviceName)
    }

    /// Parse the raw keychain data into a `DetectedCredential`.
    /// Internal access for testability.
    static func parseClaudeCodeCredential(data: Data, serviceName: String) -> DetectedCredential? {
        guard let raw = String(data: data, encoding: .utf8) else {
            Log.keychain.warning("Non-UTF8 data in '\(serviceName)'")
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let jsonData = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            Log.keychain.debug("Parsed plain token from '\(serviceName)' (length: \(trimmed.count))")
            return DetectedCredential(serviceName: serviceName, accessToken: trimmed)
        }

        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let accessToken = oauth["accessToken"] as? String {
            let refreshToken = oauth["refreshToken"] as? String
            var expiresAt: Date?
            if let expiresAtMs = oauth["expiresAt"] as? Double {
                expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000)
            }
            Log.keychain.debug("Parsed credential from '\(serviceName)' (token length: \(accessToken.count), hasRefresh: \(refreshToken != nil))")
            return DetectedCredential(serviceName: serviceName, accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
        }

        if let accessToken = json["accessToken"] as? String ?? json["access_token"] as? String {
            Log.keychain.debug("Parsed flat token from '\(serviceName)' (length: \(accessToken.count))")
            return DetectedCredential(serviceName: serviceName, accessToken: accessToken)
        }

        Log.keychain.warning("Failed to extract token from '\(serviceName)'")
        return nil
    }

    // MARK: - Clusage Token Storage

    private static let servicePrefix = "studio.seventwo.clusage.token."

    static func saveToken(_ token: String, for accountID: UUID) -> Bool {
        let service = servicePrefix + accountID.uuidString
        let data = Data(token.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]

        // Try update first
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecSuccess {
            return true
        }

        // If not found, add new
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        if addStatus != errSecSuccess {
            Log.keychain.error("Failed to save token for \(accountID.uuidString): OSStatus \(addStatus)")
        }
        return addStatus == errSecSuccess
    }

    static func loadToken(for accountID: UUID) -> String? {
        let service = servicePrefix + accountID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteToken(for accountID: UUID) {
        let service = servicePrefix + accountID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Refresh Token Storage

    private static let refreshServicePrefix = "studio.seventwo.clusage.refresh."

    static func saveRefreshToken(_ token: String, for accountID: UUID) -> Bool {
        let service = refreshServicePrefix + accountID.uuidString
        let data = Data(token.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]

        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecSuccess { return true }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        if addStatus != errSecSuccess {
            Log.keychain.error("Failed to save refresh token for \(accountID.uuidString): OSStatus \(addStatus)")
        }
        return addStatus == errSecSuccess
    }

    static func loadRefreshToken(for accountID: UUID) -> String? {
        let service = refreshServicePrefix + accountID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteRefreshToken(for accountID: UUID) {
        let service = refreshServicePrefix + accountID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
