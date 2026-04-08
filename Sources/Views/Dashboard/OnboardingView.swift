import SwiftUI

struct OnboardingView: View {
    @Bindable var viewModel: AccountsViewModel
    var onSkip: (() -> Void)?
    @State private var page = 0
    @State private var showManualEntry = false
    @State private var appeared = false
    @State private var acceptedRisk = false
    @State private var showImportSuccess = false

    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case 0:
                    welcomePage
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                case 1:
                    disclaimerPage
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                case 2:
                    keychainPermissionPage
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                default:
                    accountSetupPage
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
            }
            .animation(.smooth(duration: 0.5), value: page)

            // Page indicator dots
            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                        .animation(.easeInOut(duration: 0.2), value: page)
                }
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .transparentWindow()
        .onAppear {
            withAnimation(.easeOut(duration: 0.8).delay(0.1)) {
                appeared = true
            }
        }
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        ScrollView {
            VStack(spacing: 40) {
                header
                howItWorks

                VStack(spacing: 12) {
                    Button {
                        withAnimation { page = 1 }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Get Started")
                            Image(systemName: "arrow.right")
                        }
                        .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if onSkip != nil {
                        Button("Skip Setup") {
                            onSkip?()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    }
                }
            }
            .padding(48)
            .frame(maxWidth: .infinity)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)
        }
    }

    // MARK: - Page 2: Disclaimer

    private var disclaimerPage: some View {
        ScrollView {
            VStack(spacing: 32) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                Text("Before You Continue")
                    .font(.title.bold())

                VStack(alignment: .leading, spacing: 6) {
                    Text("This app uses an **unofficial, undocumented API** that is not endorsed by Anthropic. It may break at any time, and use of unofficial tools could result in account restrictions.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 480, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                Toggle(isOn: $acceptedRisk) {
                    Text("I understand the risks and choose to use this app at my own responsibility")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .frame(maxWidth: 480, alignment: .leading)

                Button {
                    withAnimation { page = 2 }
                } label: {
                    HStack(spacing: 6) {
                        Text("Continue")
                        Image(systemName: "arrow.right")
                    }
                    .frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!acceptedRisk)

                backButton(to: 0)
            }
            .padding(48)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Page 3: Keychain Permission

    private var keychainPermissionPage: some View {
        ScrollView {
            VStack(spacing: 32) {
                Image(systemName: "key.viewfinder")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("Import from Claude Code")
                    .font(.title.bold())

                VStack(spacing: 12) {
                    Text("Clusage can automatically find your Claude Code accounts by reading your macOS Keychain.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("This is the same Keychain that Claude Code uses to store your OAuth tokens. Clusage will only look for entries named \"Claude Code-credentials\" — nothing else is read.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 400)

                VStack(alignment: .leading, spacing: 8) {
                    permissionBullet(icon: "lock.shield", text: "Only Claude Code credentials are accessed")
                    permissionBullet(icon: "externaldrive", text: "Tokens stay on your Mac, never sent elsewhere")
                    permissionBullet(icon: "checkmark.shield", text: "You choose which accounts to import")
                }
                .frame(maxWidth: 400, alignment: .leading)

                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "info.circle.fill")
                        .font(.body)
                        .imageScale(.large)
                        .foregroundStyle(.blue)
                        .frame(width: 28, alignment: .center)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    Text("macOS will ask for your login password to read the Keychain. This is a standard system prompt — click **Allow** to continue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: 400, alignment: .leading)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                VStack(spacing: 12) {
                    Button {
                        let vm = viewModel
                        Task { @MainActor in
                            await vm.detectCredentials()
                            withAnimation { page = 3 }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                            Text("Scan Keychain")
                        }
                        .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Enter token manually instead") {
                        showManualEntry = true
                        withAnimation { page = 3 }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                backButton(to: 1)
            }
            .padding(48)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Page 4: Account Setup

    private var accountSetupPage: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 8) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                    Text("Add an Account")
                        .font(.title.bold())
                }

                if viewModel.hasDetectedCredentials && !showManualEntry {
                    detectedCredentialsSection
                } else {
                    manualEntrySection
                }

                backButton(to: 2)
            }
            .padding(48)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Shared

    private func backButton(to targetPage: Int) -> some View {
        Button {
            withAnimation { page = targetPage }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left")
                Text("Back")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .font(.callout)
    }

    private func permissionBullet(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: icon)
                .font(.body)
                .imageScale(.large)
                .foregroundStyle(.green)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 16) {
            AppIconView()

            Text("Welcome to Clusage")
                .font(.largeTitle.bold())

            Text("Track your Claude API usage across multiple accounts,\nright from your menu bar.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - How it works

    private var howItWorks: some View {
        VStack(spacing: 0) {
            FeatureRow(
                icon: "key.fill",
                title: "Connect with an OAuth token",
                description: "Uses the same Anthropic OAuth API as Claude Code. Your token stays local on your Mac."
            )

            FeatureRow(
                icon: "arrow.triangle.2.circlepath",
                title: "Smart polling",
                description: "Adapts to your activity — faster when active, slower when idle, paused when locked."
            )

            FeatureRow(
                icon: "chart.xyaxis.line",
                title: "History and insights",
                description: "Snapshots every 5 minutes, kept for 30 days. See trends and pace over time."
            )

            FeatureRow(
                icon: "widget.small",
                title: "Desktop widget",
                description: "See your usage at a glance without opening anything."
            )
        }
        .frame(maxWidth: 480)
    }

    // MARK: - Credential row

    private func credentialRow(_ credential: DetectedCredential) -> some View {
        let isSelected = viewModel.selectedCredentialIDs.contains(credential.id)
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                viewModel.toggleCredential(credential)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(credential.label)
                        .font(.body.weight(.medium))
                    if let email = credential.email {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(credential.label)\(credential.email.map { ", \($0)" } ?? "")")
        .accessibilityValue(isSelected ? "selected" : "not selected")
        .accessibilityHint("Double-tap to toggle selection")
    }

    // MARK: - Detected credentials

    private var detectedCredentialsSection: some View {
        VStack(spacing: 20) {
            Label(
                "\(viewModel.detectedCredentials.count) account\(viewModel.detectedCredentials.count == 1 ? "" : "s") found",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.headline)

            Text("Select which accounts to import.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(viewModel.detectedCredentials, id: \.id) { credential in
                    credentialRow(credential)
                }
            }
            .frame(maxWidth: 400)

            if let error = viewModel.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showImportSuccess {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: showImportSuccess)

                    Text("\(viewModel.importedCount) account\(viewModel.importedCount == 1 ? "" : "s") imported")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
                .transition(.opacity.combined(with: .scale))
            }

            Button {
                let vm = viewModel
                Task { @MainActor in
                    await vm.importSelected()
                    if vm.importedCount > 0 {
                        withAnimation(.spring(duration: 0.5)) {
                            showImportSuccess = true
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isImporting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(viewModel.isImporting ? "Importing..." : "Import Selected")
                }
                .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.selectedCredentialIDs.isEmpty || viewModel.isImporting)

            Button("Add manually instead") {
                withAnimation { showManualEntry = true }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    // MARK: - Manual entry

    private var manualEntrySection: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                TextField("Account Name", text: $viewModel.newAccountName)
                    .textFieldStyle(.roundedBorder)

                SecureField("OAuth Token", text: $viewModel.newAccountToken)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: 340)

            if let error = viewModel.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button {
                let vm = viewModel
                Task { @MainActor in await vm.addAccount() }
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isValidating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(viewModel.isValidating ? "Validating..." : "Add Account")
                }
                .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                viewModel.newAccountName.isEmpty
                || viewModel.newAccountToken.isEmpty
                || viewModel.isValidating
            )

            Text("Paste an OAuth token from your Anthropic account settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            if viewModel.hasDetectedCredentials {
                Button("Back to detected accounts") {
                    withAnimation { showManualEntry = false }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .frame(maxWidth: 440)
    }
}

// MARK: - App Icon View

private struct AppIconView: View {
    @State private var iconImage: NSImage?

    var body: some View {
        Group {
            if let iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            } else {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white)
                    .padding(20)
                    .glassEffect(.regular.tint(.accentColor), in: Circle())
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            iconImage = NSApp.applicationIconImage
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.body)
                .imageScale(.large)
                .foregroundStyle(.tint)
                .frame(width: 28, alignment: .center)
                .padding(.top, 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }
}
