import SwiftUI

struct AccountsPageView: View {
    let accountStore: AccountStore
    var poller: UsagePoller?
    @State private var detectedCredentials: [DetectedCredential] = []
    @State private var isDetecting = true
    @State private var importingIDs: Set<UUID> = []
    @State private var importErrors: [UUID: String] = [:]
    @State private var accountToDelete: Account?

    // Custom token
    @State private var showCustomToken = false
    @State private var customName = ""
    @State private var customToken = ""
    @State private var isValidatingCustom = false
    @State private var customError: String?

    /// Credentials not yet added as accounts (filter by keychain service name).
    private var unlinkedCredentials: [DetectedCredential] {
        let linked = Set(accountStore.accounts.compactMap(\.keychainServiceName))
        return detectedCredentials.filter { !linked.contains($0.serviceName) }
    }

    var body: some View {
        Form {
            // Existing accounts
            if !accountStore.accounts.isEmpty {
                Section {
                    ForEach(accountStore.accounts) { account in
                        AccountRow(account: account, accountStore: accountStore) {
                            accountToDelete = account
                        }
                    }
                }
            }

            // Detected credentials (not yet added)
            if !isDetecting && !unlinkedCredentials.isEmpty {
                Section("Detected Accounts") {
                    ForEach(unlinkedCredentials) { credential in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(credential.label)
                                        .font(.body.weight(.medium))
                                    Text(credential.sourceDescription)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                if importingIDs.contains(credential.id) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel("Importing \(credential.label)")
                                } else {
                                    Button("Add") {
                                        importCredential(credential)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .accessibilityLabel("Add \(credential.label)")
                                }
                            }

                            if let error = importErrors[credential.id] {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }

            if isDetecting {
                Section {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning keychain…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Add custom token
            Section {
                if showCustomToken {
                    VStack(spacing: 10) {
                        TextField("Account Name", text: $customName)
                            .textFieldStyle(.roundedBorder)

                        SecureField("OAuth Token", text: $customToken)
                            .textFieldStyle(.roundedBorder)

                        if let error = customError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }

                        HStack {
                            Button("Cancel") {
                                showCustomToken = false
                                customName = ""
                                customToken = ""
                                customError = nil
                            }

                            Spacer()

                            Button {
                                addCustomAccount()
                            } label: {
                                HStack(spacing: 6) {
                                    if isValidatingCustom {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                    Text(isValidatingCustom ? "Validating…" : "Add")
                                }
                            }
                            .disabled(customName.isEmpty || customToken.isEmpty || isValidatingCustom)
                        }
                    }
                } else {
                    Button {
                        showCustomToken = true
                    } label: {
                        Label("Add Custom Token", systemImage: "plus")
                    }
                }
            }

            if accountStore.accounts.isEmpty && !isDetecting && unlinkedCredentials.isEmpty {
                ContentUnavailableView {
                    Label("No Accounts", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("No Claude Code credentials found in Keychain. Add an account with a custom token above.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Accounts")
        .task {
            await detectCredentials()
        }
        .confirmationDialog(
            "Remove \(accountToDelete?.displayName ?? "account")?",
            isPresented: Binding(
                get: { accountToDelete != nil },
                set: { if !$0 { accountToDelete = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let account = accountToDelete {
                    accountStore.removeAccount(account)
                }
                accountToDelete = nil
            }
        } message: {
            Text("The account and its token will be removed. This cannot be undone.")
        }
    }

    private func detectCredentials() async {
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

        for i in credentials.indices {
            do {
                let profile = try await APIClient.shared.fetchProfile(token: credentials[i].accessToken)
                credentials[i].email = profile.account.email
            } catch {
                Log.accounts.warning("Could not fetch profile for '\(credentials[i].serviceName)': \(error.localizedDescription)")
            }
        }

        detectedCredentials = credentials
        isDetecting = false
    }

    private func importCredential(_ credential: DetectedCredential) {
        importingIDs.insert(credential.id)
        importErrors.removeValue(forKey: credential.id)

        Task { @MainActor in
            defer { importingIDs.remove(credential.id) }

            do {
                _ = try await APIClient.shared.validateToken(credential.accessToken)
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
                poller?.pollNewAccountsIfNeeded()
                Log.accounts.info("Imported credential '\(credential.label)' as '\(name)'")
            } catch {
                importErrors[credential.id] = error.localizedDescription
                Log.accounts.warning("Failed to import '\(credential.label)': \(error.localizedDescription)")
            }
        }
    }

    private func addCustomAccount() {
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = customToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty, !token.isEmpty else {
            customError = "Name and token are required."
            return
        }

        isValidatingCustom = true
        customError = nil

        Task { @MainActor in
            defer { isValidatingCustom = false }

            do {
                _ = try await APIClient.shared.validateToken(token)
                let profile = try await APIClient.shared.fetchProfile(token: token)

                // Auto-detect keychain binding
                let keychainService = detectedCredentials.first(where: { $0.accessToken == token })?.serviceName

                accountStore.addAccount(
                    name: name,
                    token: token,
                    profile: Profile(from: profile),
                    keychainServiceName: keychainService
                )
                poller?.pollNewAccountsIfNeeded()

                customName = ""
                customToken = ""
                showCustomToken = false
            } catch {
                customError = error.localizedDescription
            }
        }
    }
}

private struct AccountRow: View {
    let account: Account
    let accountStore: AccountStore
    var onDelete: () -> Void
    @State private var showingRelinkSheet = false
    @State private var showingCredentialsPathSheet = false

    private var isMenuBarAccount: Bool {
        accountStore.menuBarAccountID == account.id
            || (accountStore.menuBarAccountID == nil && account.id == accountStore.accounts.first?.id)
    }

    private var needsRelink: Bool {
        guard let error = account.lastError else { return false }
        return error.contains("Re-link") || error.contains("keychain entry") || error.contains("mismatch")
            || account.keychainServiceName == nil
    }

    var body: some View {
        HStack {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.body.weight(.medium))

                if let error = account.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let lastUpdated = account.lastUpdated {
                    Text("Updated \(DateFormatting.relativeTime(from: lastUpdated))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let customPath = account.credentialsFilePath {
                    Text(customPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if account.lastError != nil {
                if needsRelink {
                    Button {
                        showingRelinkSheet = true
                    } label: {
                        Label("Re-link Keychain", systemImage: "key.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Link this account to a different keychain entry")
                } else {
                    Button {
                        _ = accountStore.refreshTokenFromKeychain(for: account)
                    } label: {
                        Label("Refresh Token", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Try to refresh the token from Keychain")
                }
            }

            if isMenuBarAccount {
                Image(systemName: "menubar.rectangle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Shown in menu bar")
                    .accessibilityLabel("Shown in menu bar")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove account")
            .help("Remove account")
        }
        .contextMenu {
            Button("Set as Menu Bar Account") {
                accountStore.menuBarAccountID = account.id
            }

            Button("Set Credentials File Path…") {
                showingCredentialsPathSheet = true
            }

            Button("Re-link Keychain Entry…") {
                showingRelinkSheet = true
            }

            Divider()

            Button("Remove Account…", role: .destructive) {
                onDelete()
            }
        }
        .sheet(isPresented: $showingRelinkSheet) {
            RelinkKeychainView(account: account, accountStore: accountStore)
        }
        .sheet(isPresented: $showingCredentialsPathSheet) {
            CredentialsPathSheet(account: account, accountStore: accountStore)
        }
    }
}

/// Sheet that lets the user pick a keychain entry to link to an account.
private struct RelinkKeychainView: View {
    let account: Account
    let accountStore: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var credentials: [DetectedCredential] = []
    @State private var isLoading = true
    @State private var isValidating = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Re-link Keychain")
                .font(.title2.bold())

            Text("Choose which keychain entry belongs to **\(account.displayName)**.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isLoading {
                ProgressView("Scanning keychain…")
            } else if credentials.isEmpty {
                Label("No Claude Code credentials found in Keychain.", systemImage: "key.slash")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(credentials) { credential in
                        Button {
                            relink(to: credential)
                        } label: {
                            HStack {
                                Image(systemName: "key.fill")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(credential.label)
                                        .font(.body.weight(.medium))
                                    Text(credential.sourceDescription)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if credential.serviceName == account.keychainServiceName {
                                    Text("current")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.secondary.opacity(0.1), in: Capsule())
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if isValidating {
                ProgressView("Validating…")
                    .controlSize(.small)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 420)
        .task {
            await loadCredentials()
        }
    }

    private func loadCredentials() async {
        var creds = KeychainManager.detectAllClaudeCodeCredentials()
        for i in creds.indices {
            do {
                let profile = try await APIClient.shared.fetchProfile(token: creds[i].accessToken)
                creds[i].email = profile.account.email
            } catch {
                Log.accounts.warning("Could not fetch profile for '\(creds[i].serviceName)': \(error.localizedDescription)")
            }
        }
        credentials = creds
        isLoading = false
    }

    private func relink(to credential: DetectedCredential) {
        isValidating = true
        error = nil

        Task { @MainActor in
            do {
                _ = try await APIClient.shared.validateToken(credential.accessToken)
            } catch {
                self.error = "Token validation failed: \(error.localizedDescription)"
                isValidating = false
                return
            }

            if let expectedEmail = account.profile?.email,
               let credentialEmail = credential.email,
               credentialEmail != expectedEmail {
                self.error = "This credential belongs to \(credentialEmail), not \(expectedEmail)."
                isValidating = false
                return
            }

            if account.profile == nil, let email = credential.email {
                var updated = account
                updated.profile = Profile(email: email)
                accountStore.updateAccount(updated)
            }

            accountStore.relinkKeychain(for: account, credential: credential)
            isValidating = false
            dismiss()
        }
    }
}

/// Sheet to set a custom credentials file path per account.
private struct CredentialsPathSheet: View {
    let account: Account
    let accountStore: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: String = ""
    @State private var validationStatus: ValidationStatus = .idle

    private enum ValidationStatus: Equatable {
        case idle
        case valid
        case invalid(String)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Credentials File")
                .font(.title2.bold())

            Text("Set the path to the `.credentials.json` file for **\(account.displayName)**.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField(CredentialsFileReader.defaultPath, text: $path)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    Button("Browse…") { browseForFile() }
                }

                switch validationStatus {
                case .idle:
                    EmptyView()
                case .valid:
                    Label("File found — contains a valid token", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .invalid(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            HStack {
                if account.credentialsFilePath != nil {
                    Button("Reset to Default") {
                        var updated = account
                        updated.credentialsFilePath = nil
                        accountStore.updateAccount(updated)
                        dismiss()
                    }
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            path = account.credentialsFilePath ?? ""
        }
        .onChange(of: path) {
            validate()
        }
    }

    private func validate() {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationStatus = .idle
            return
        }

        if let _ = CredentialsFileReader.read(path: trimmed) {
            validationStatus = .valid
        } else {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                validationStatus = .invalid("File exists but doesn't contain a valid credential")
            } else {
                validationStatus = .invalid("File not found")
            }
        }
    }

    private func save() {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = account
        updated.credentialsFilePath = trimmed.isEmpty ? nil : trimmed
        // If sourced from keychain, switch to credentials-file source
        if CredentialsFileReader.read(path: trimmed) != nil {
            updated.keychainServiceName = CredentialsFileReader.serviceName
        }
        accountStore.updateAccount(updated)
        dismiss()
    }

    private func browseForFile() {
        let panel = NSOpenPanel()
        panel.title = "Select .credentials.json"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")

        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}
