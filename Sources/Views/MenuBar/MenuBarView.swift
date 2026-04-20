import SwiftUI

struct MenuBarView: View {
    @Bindable var viewModel: MenuBarViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.hasAccounts {
                VStack(spacing: 2) {
                    Picker("Account", selection: $viewModel.selectedAccountID) {
                        ForEach(viewModel.accounts) { account in
                            Text(account.displayName).tag(Optional(account.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Select account")
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                    if let account = viewModel.selectedAccount {
                        UsageSummaryRow(
                            account: account,
                            momentum: viewModel.momentum,
                            projection: viewModel.projection,
                            dailyTarget: viewModel.dailyTarget
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 0)
                .padding(.bottom, 14)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No accounts yet")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Open the dashboard to get started.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Get Started") {
                        openDashboard()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(20)
            }

            if let checker = viewModel.updateChecker, let release = checker.availableRelease {
                Divider()
                    .padding(.horizontal, 12)
                UpdateBannerRow(checker: checker, release: release)
            }

            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 8) {
                Button {
                    openDashboard()
                } label: {
                    Text("Open Dashboard")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    Task { await viewModel.poller?.pollNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.callout.weight(.medium))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Refresh usage data")
                .help("Refresh now")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.callout.weight(.medium))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Quit Clusage")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
    }

    private func openDashboard() {
        openWindow(id: "dashboard")
        bringDashboardToFront()
    }
}

private struct UpdateBannerRow: View {
    @Bindable var checker: UpdateChecker
    let release: UpdateChecker.Release
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available")
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            actionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var subtitle: String {
        switch checker.installState {
        case .idle: "Version \(release.version)"
        case .downloading(let p): "Downloading… \(Int(p * 100))%"
        case .verifying: "Verifying signature…"
        case .installing: "Installing…"
        case .failed(let msg): msg
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch checker.installState {
        case .idle:
            if release.dmgURL != nil {
                Button("Install") {
                    Task { await checker.downloadAndInstall() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button("Open") { openURL(release.htmlURL) }
                    .controlSize(.small)
            }
        case .downloading, .verifying, .installing:
            ProgressView().controlSize(.small)
        case .failed:
            Button("Retry") {
                checker.resetInstallState()
                Task { await checker.downloadAndInstall() }
            }
            .controlSize(.small)
        }
    }
}

/// Activate the app and move the Dashboard window to the current Space.
@MainActor func bringDashboardToFront() {
    NSApp.activate()
    if let window = NSApp.windows.first(where: { $0.title == "Dashboard" }) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
    }
}
