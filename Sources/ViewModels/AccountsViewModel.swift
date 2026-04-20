import Foundation

@MainActor @Observable
final class AccountsViewModel {
    let accountStore: AccountStore
    var newAccountName = ""
    var newAccountToken = ""
    /// Keychain service name of the selected credential (if any).
    var selectedKeychainServiceName: String?
    var error: String?
    var isValidating = false

    /// All Claude Code credentials found in the Keychain.
    var detectedCredentials: [DetectedCredential] = []

    /// IDs of credentials selected for import.
    var selectedCredentialIDs: Set<UUID> = []

    /// Whether we're currently importing selected credentials.
    var isImporting = false

    /// Number of accounts successfully imported in the last batch.
    var importedCount = 0

    /// Called after accounts are successfully added/imported so the poller can fetch data immediately.
    var onAccountsAdded: (() -> Void)?

    init(accountStore: AccountStore) {
        self.accountStore = accountStore
    }

    var accounts: [Account] {
        accountStore.accounts
    }

    var hasDetectedCredentials: Bool {
        !detectedCredentials.isEmpty
    }

    /// Validates the token against the API, then saves the account.
    /// The account must be linked to a keychain entry — if none was selected, we auto-detect
    /// which keychain credential holds this token.
    func addAccount() async {
        let name = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = newAccountToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty, !token.isEmpty else {
            error = "Name and token are required."
            Log.accounts.warning("addAccount called with empty name or token")
            return
        }

        Log.accounts.info("Adding account '\(name)' — validating token (length: \(token.count))")
        isValidating = true
        error = nil

        do {
            let profile = try await APIClient.shared.fetchProfile(token: token)

            // Resolve keychain binding: use selected credential, or match against
            // already-detected credentials (avoids a new keychain scan + prompts)
            let matchedCredential = detectedCredentials.first(where: { $0.accessToken == token })
            var keychainService = selectedKeychainServiceName
            if keychainService == nil {
                keychainService = matchedCredential?.serviceName
                if let service = keychainService {
                    Log.accounts.info("Auto-detected keychain entry '\(service)' for manual token")
                }
            }

            accountStore.addAccount(
                name: name,
                token: token,
                profile: Profile(from: profile),
                keychainServiceName: keychainService,
                refreshToken: matchedCredential?.refreshToken,
                tokenExpiresAt: matchedCredential?.expiresAt
            )
            Log.accounts.info("Account '\(name)' added successfully (keychain: \(keychainService ?? "none"))")
            newAccountName = ""
            newAccountToken = ""
            selectedKeychainServiceName = nil
            error = nil
            onAccountsAdded?()
        } catch {
            Log.accounts.error("Failed to add account '\(name)': \(error.localizedDescription)")
            self.error = error.localizedDescription
        }

        isValidating = false
    }

    func removeAccount(_ account: Account) {
        accountStore.removeAccount(account)
    }

    /// Discover Claude Code credentials from both the credentials file and keychain.
    /// Both sources are prompt-free — the credentials file is read directly, and the
    /// keychain is read via the security CLI (matches `apple-tool:` partition_id).
    func detectCredentials() async {
        var credentials: [DetectedCredential] = []

        // Credentials file (fastest, no subprocess)
        if let fileCred = CredentialsFileReader.read() {
            credentials.append(fileCred)
        }

        // Keychain via security CLI (prompt-free)
        let keychainCreds = KeychainManager.detectAllClaudeCodeCredentials()
        let existingTokens = Set(credentials.map(\.accessToken))
        for cred in keychainCreds where !existingTokens.contains(cred.accessToken) {
            credentials.append(cred)
        }

        // Fetch profile for each credential to get email
        for i in credentials.indices {
            do {
                let profile = try await APIClient.shared.fetchProfile(token: credentials[i].accessToken)
                credentials[i].email = profile.account.email
            } catch {
                Log.accounts.warning("Could not fetch profile for '\(credentials[i].serviceName)': \(error.localizedDescription)")
            }
        }

        detectedCredentials = credentials
        // Select all by default
        selectedCredentialIDs = Set(credentials.map(\.id))
    }

    func toggleCredential(_ credential: DetectedCredential) {
        if selectedCredentialIDs.contains(credential.id) {
            selectedCredentialIDs.remove(credential.id)
        } else {
            selectedCredentialIDs.insert(credential.id)
        }
    }

    /// Select a specific detected credential to fill the manual form.
    func selectCredential(_ credential: DetectedCredential) {
        newAccountToken = credential.accessToken
        newAccountName = credential.label
        selectedKeychainServiceName = credential.serviceName
    }

    /// Import only the selected detected credentials as accounts.
    func importSelected() async {
        let toImport = detectedCredentials.filter { selectedCredentialIDs.contains($0.id) }
        Log.accounts.info("importSelected called — \(toImport.count) credential(s) selected")
        guard !toImport.isEmpty else {
            error = "No accounts selected."
            return
        }

        isImporting = true
        error = nil
        importedCount = 0

        // Deduplicate credentials that share the same token
        // (Claude Code may store the same OAuth token under multiple keychain entries)
        var seenTokens: Set<String> = []
        let uniqueImports = toImport.filter { seenTokens.insert($0.accessToken).inserted }
        if uniqueImports.count < toImport.count {
            Log.accounts.info("Filtered \(toImport.count - uniqueImports.count) duplicate token(s)")
        }

        var failedLabels: [String] = []
        for credential in uniqueImports {
            do {
                let profile = try await APIClient.shared.fetchProfile(token: credential.accessToken)
                let name = profile.account.email
                accountStore.addAccount(
                    name: name,
                    token: credential.accessToken,
                    profile: Profile(from: profile),
                    keychainServiceName: credential.serviceName,
                    refreshToken: credential.refreshToken,
                    tokenExpiresAt: credential.expiresAt
                )
                importedCount += 1
                Log.accounts.info("Imported credential '\(credential.label)' as '\(name)'")
            } catch {
                failedLabels.append(credential.label)
                Log.accounts.warning("Skipping credential '\(credential.label)': \(error.localizedDescription)")
            }
        }

        isImporting = false

        if importedCount > 0 {
            onAccountsAdded?()
        }

        if failedLabels.count == uniqueImports.count {
            self.error = "Selected tokens could not be validated. They may have expired."
        } else if !failedLabels.isEmpty {
            self.error = "Could not import \(failedLabels.count) account(s): \(failedLabels.joined(separator: ", ")). Tokens may have expired."
        }
    }
}
