import Foundation
import Observation

@Observable
@MainActor final class AccountStore {
    private(set) var accounts: [Account] = []

    /// The account shown in the menu bar icon. Falls back to first account.
    var menuBarAccountID: UUID? {
        didSet { defaults.set(menuBarAccountID?.uuidString, forKey: menuBarAccountKey) }
    }

    var menuBarAccount: Account? {
        if let id = menuBarAccountID, let match = accounts.first(where: { $0.id == id }) {
            return match
        }
        return accounts.first
    }

    private let defaults = UserDefaults.standard
    private let storageKey = DefaultsKeys.accounts
    private let menuBarAccountKey = DefaultsKeys.menuBarAccountID
    /// In-memory token map loaded once from Keychain at init.
    private var tokens: [String: String] = [:]

    init() {
        loadAccounts()
        loadTokensFromKeychain()
        if let raw = defaults.string(forKey: menuBarAccountKey), let id = UUID(uuidString: raw) {
            menuBarAccountID = id
        }
    }

    func addAccount(
        name: String,
        token: String,
        profile: Profile? = nil,
        keychainServiceName: String? = nil,
        refreshToken: String? = nil,
        tokenExpiresAt: Date? = nil,
        credentialsFilePath: String? = nil
    ) {
        var account = Account(name: name)
        account.profile = profile
        account.keychainServiceName = keychainServiceName
        account.tokenExpiresAt = tokenExpiresAt
        account.credentialsFilePath = credentialsFilePath
        Log.accounts.info("Adding account '\(name)' (\(account.id.uuidString))")
        tokens[account.id.uuidString] = token
        accounts.append(account)
        saveAccounts()
        _ = KeychainManager.saveToken(token, for: account.id)
        if let refreshToken {
            _ = KeychainManager.saveRefreshToken(refreshToken, for: account.id)
        }
        Log.accounts.info("Account added. Total accounts: \(self.accounts.count)")
    }

    func removeAccount(_ account: Account) {
        Log.accounts.info("Removing account '\(account.name)' (\(account.id.uuidString))")
        tokens.removeValue(forKey: account.id.uuidString)
        accounts.removeAll { $0.id == account.id }
        if menuBarAccountID == account.id {
            menuBarAccountID = accounts.first?.id
        }
        saveAccounts()
        KeychainManager.deleteToken(for: account.id)
        KeychainManager.deleteRefreshToken(for: account.id)
        Log.accounts.info("Account removed. Total accounts: \(self.accounts.count)")
    }

    func removeAllAccounts() {
        Log.accounts.info("Removing all \(self.accounts.count) account(s)")
        for account in accounts {
            tokens.removeValue(forKey: account.id.uuidString)
            KeychainManager.deleteToken(for: account.id)
            KeychainManager.deleteRefreshToken(for: account.id)
        }
        accounts.removeAll()
        menuBarAccountID = nil
        saveAccounts()
        Log.accounts.info("All accounts removed")
    }

    func moveAccounts(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        saveAccounts()
    }

    func updateAccount(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else {
            Log.accounts.warning("updateAccount called for unknown account \(account.id.uuidString)")
            return
        }
        accounts[index] = account
        saveAccounts()
    }

    func token(for account: Account) -> String? {
        tokens[account.id.uuidString]
    }

    /// Update the stored token for an account.
    func updateToken(_ token: String, for account: Account) {
        tokens[account.id.uuidString] = token
        _ = KeychainManager.saveToken(token, for: account.id)
    }

    /// The email associated with an account — checks profile first, falls back to name.
    func email(for account: Account) -> String? {
        if let email = account.profile?.email { return email }
        // The name is often the email (set during import)
        if account.name.contains("@") { return account.name }
        return nil
    }

    /// Try to refresh from the credentials file only (no keychain, no prompts).
    /// Uses the account's custom `credentialsFilePath` if set, otherwise the default.
    /// Returns the new token if the file has a different (presumably fresher) token, nil otherwise.
    func refreshTokenFromCredentialsFile(for account: Account) -> String? {
        guard let fileCred = CredentialsFileReader.read(path: account.credentialsFilePath) else { return nil }
        let oldToken = tokens[account.id.uuidString]
        guard fileCred.accessToken != oldToken else { return nil }

        Log.accounts.info("[\(account.displayName)] Refreshed token from credentials file")
        tokens[account.id.uuidString] = fileCred.accessToken
        _ = KeychainManager.saveToken(fileCred.accessToken, for: account.id)
        if let refreshToken = fileCred.refreshToken {
            _ = KeychainManager.saveRefreshToken(refreshToken, for: account.id)
        }
        return fileCred.accessToken
    }

    /// Refresh the token for an account. Tries the credentials file for file-sourced accounts,
    /// falls back to keychain for keychain-sourced accounts (prompt-free via security CLI).
    func refreshTokenFromKeychain(for account: Account) -> String? {
        // For credentials-file-sourced accounts, re-read the file (no prompts)
        if account.keychainServiceName == CredentialsFileReader.serviceName {
            guard let fileCred = CredentialsFileReader.read(path: account.credentialsFilePath) else {
                Log.accounts.warning("[\(account.displayName)] Credentials file unavailable")
                return nil
            }
            let oldToken = tokens[account.id.uuidString]
            if fileCred.accessToken != oldToken {
                Log.accounts.info("[\(account.displayName)] Refreshed token from credentials file")
                tokens[account.id.uuidString] = fileCred.accessToken
                _ = KeychainManager.saveToken(fileCred.accessToken, for: account.id)
                if let refreshToken = fileCred.refreshToken {
                    _ = KeychainManager.saveRefreshToken(refreshToken, for: account.id)
                }
            }
            return fileCred.accessToken
        }

        // Keychain-sourced accounts: read from keychain via security CLI (prompt-free)
        guard let serviceName = account.keychainServiceName else {
            Log.accounts.warning("[\(account.displayName)] No keychain binding — cannot refresh token")
            return nil
        }

        guard let credential = KeychainManager.fetchClaudeCodeCredential(serviceName: serviceName) else {
            Log.accounts.warning("[\(account.displayName)] Keychain entry '\(serviceName)' not found")
            // Mark the account so the UI can show a re-link button
            if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[idx].lastError = "Keychain entry not found. Re-link this account to a keychain entry."
                saveAccounts()
            }
            return nil
        }

        let oldToken = tokens[account.id.uuidString]
        if credential.accessToken != oldToken {
            Log.accounts.info("[\(account.displayName)] Refreshed token from keychain '\(serviceName)'")
            tokens[account.id.uuidString] = credential.accessToken
            _ = KeychainManager.saveToken(credential.accessToken, for: account.id)
        } else {
            Log.accounts.debug("[\(account.displayName)] Keychain token unchanged")
        }
        return credential.accessToken
    }

    /// Try to self-refresh the token using the stored OAuth refresh token.
    /// Returns the new access token on success, nil if no refresh token is stored or refresh fails.
    func selfRefreshToken(for account: Account) async -> String? {
        guard let refreshToken = KeychainManager.loadRefreshToken(for: account.id) else {
            Log.accounts.debug("[\(account.displayName)] No refresh token stored — cannot self-refresh")
            return nil
        }

        do {
            let response = try await APIClient.shared.refreshAccessToken(refreshToken: refreshToken)

            // Store the new access token
            tokens[account.id.uuidString] = response.accessToken
            _ = KeychainManager.saveToken(response.accessToken, for: account.id)

            // Store the new refresh token if provided (token rotation)
            if let newRefresh = response.refreshToken {
                _ = KeychainManager.saveRefreshToken(newRefresh, for: account.id)
            }

            // Update expiry on the account — re-read from store to avoid
            // overwriting fields changed by other operations in the same poll cycle
            if let expiresIn = response.expiresIn {
                var updated = accounts.first { $0.id == account.id } ?? account
                updated.tokenExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
                updateAccount(updated)
            }

            Log.accounts.info("[\(account.displayName)] Self-refreshed token successfully")
            return response.accessToken
        } catch {
            Log.accounts.warning("[\(account.displayName)] Self-refresh failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Eagerly refresh tokens from the credentials file on startup.
    /// Only refreshes file-sourced accounts for speed — keychain reads are also prompt-free
    /// (via security CLI), but file reads are faster. Stale keychain-bound tokens refresh on 401.
    @discardableResult
    func refreshAllFromKeychain() -> Bool {
        let fileAccounts = accounts.filter { $0.keychainServiceName == CredentialsFileReader.serviceName }
        guard !fileAccounts.isEmpty else {
            Log.accounts.debug("No credentials-file accounts — skipping eager refresh")
            return false
        }

        Log.accounts.info("Refreshing tokens from credentials file for \(fileAccounts.count) account(s)")
        var refreshedAny = false

        for account in fileAccounts {
            guard let fileCred = CredentialsFileReader.read(path: account.credentialsFilePath) else {
                Log.accounts.debug("[\(account.displayName)] Credentials file not available")
                continue
            }

            let oldToken = tokens[account.id.uuidString]
            guard fileCred.accessToken != oldToken else { continue }

            Log.accounts.info("[\(account.displayName)] Refreshed token from credentials file")
            tokens[account.id.uuidString] = fileCred.accessToken
            _ = KeychainManager.saveToken(fileCred.accessToken, for: account.id)
            if let refreshToken = fileCred.refreshToken {
                _ = KeychainManager.saveRefreshToken(refreshToken, for: account.id)
            }
            refreshedAny = true
        }

        return refreshedAny
    }

    /// Re-link an account to a different keychain entry. Used when the original entry
    /// disappears or an email mismatch is detected.
    func relinkKeychain(for account: Account, credential: DetectedCredential) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].keychainServiceName = credential.serviceName
        accounts[idx].lastError = nil
        tokens[account.id.uuidString] = credential.accessToken
        saveAccounts()
        _ = KeychainManager.saveToken(credential.accessToken, for: account.id)
        Log.accounts.info("[\(account.displayName)] Re-linked to keychain '\(credential.serviceName)'")
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = defaults.data(forKey: storageKey) else {
            Log.accounts.info("No saved accounts found in UserDefaults")
            return
        }

        // Try decoding the full array first (fast path).
        if let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = decoded
            Log.accounts.info("Loaded \(self.accounts.count) account(s) from UserDefaults")
            return
        }

        // If the array fails, decode element-by-element so one corrupt account
        // doesn't destroy the entire list.
        Log.accounts.warning("Array decode failed — attempting per-element recovery")
        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            Log.accounts.error("Stored accounts data is not a JSON array — starting fresh")
            accounts = []
            return
        }

        let decoder = JSONDecoder()
        var recovered: [Account] = []
        for (index, element) in jsonArray.enumerated() {
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { continue }
            do {
                recovered.append(try decoder.decode(Account.self, from: elementData))
            } catch {
                Log.accounts.error("Skipping corrupt account at index \(index): \(error.localizedDescription)")
            }
        }

        accounts = recovered
        if recovered.count < jsonArray.count {
            Log.accounts.warning("Recovered \(recovered.count) of \(jsonArray.count) account(s) — re-saving clean data")
            saveAccounts()
        } else {
            Log.accounts.info("Recovered all \(recovered.count) account(s)")
        }
    }

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else {
            Log.accounts.error("Failed to encode accounts for saving")
            return
        }
        defaults.set(data, forKey: storageKey)
        Log.accounts.debug("Saved \(self.accounts.count) account(s) to UserDefaults")
    }

    /// Load each account's token from the Keychain into the in-memory cache.
    private func loadTokensFromKeychain() {
        tokens = [:]
        var missingCount = 0
        for account in accounts {
            if let token = KeychainManager.loadToken(for: account.id) {
                tokens[account.id.uuidString] = token
            } else {
                missingCount += 1
                Log.accounts.warning("No keychain token for '\(account.displayName)' (\(account.id.uuidString))")
            }
        }
        if !accounts.isEmpty {
            Log.accounts.info("Loaded \(self.tokens.count) of \(self.accounts.count) token(s) from Keychain")
        }
        if missingCount > 0 {
            Log.accounts.warning("\(missingCount) account(s) have no stored token — they will fail on first poll")
        }
    }

}
