import SwiftUI

struct DashboardView: View {
    @Bindable var viewModel: DashboardViewModel

    var body: some View {
        Group {
            if viewModel.accounts.isEmpty {
                OnboardingContainer(accountStore: viewModel.accountStore, poller: viewModel.poller)
            } else {
                NavigationSplitView {
                    AccountListView(
                        accountStore: viewModel.accountStore,
                        selectedItem: $viewModel.selectedItem
                    )
                    .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 240)
                } detail: {
                    if viewModel.selectedItem == .accounts {
                        AccountsPageView(accountStore: viewModel.accountStore, poller: viewModel.poller)
                    } else if viewModel.selectedItem == .schedule {
                        SchedulePageView(
                            accountStore: viewModel.accountStore,
                            momentumProvider: viewModel.momentumProvider
                        )
                    } else if viewModel.selectedItem == .settings {
                        SettingsView(
                            accountStore: viewModel.accountStore,
                            momentumProvider: viewModel.momentumProvider,
                            historyStore: viewModel.historyStore,
                            streakStore: viewModel.streakStore
                        )
                    } else if viewModel.selectedItem == .samples {
                        SamplesPageView(
                            historyStore: viewModel.historyStore,
                            accountStore: viewModel.accountStore
                        )
                    } else if viewModel.selectedItem == .disclaimer {
                        DisclaimerView()
                    } else if let account = viewModel.selectedAccount {
                        AccountDetailView(
                            account: account,
                            snapshots: viewModel.snapshots(for: account),
                            gaps: viewModel.gaps,
                            momentum: viewModel.momentum(for: account),
                            burstSummary: viewModel.burstSummary(for: account),
                            streak: viewModel.streak(for: account),
                            projection: viewModel.projection(for: account),
                            dailyTarget: viewModel.dailyTarget(for: account),
                            hasScheduleOverride: viewModel.hasScheduleOverride(for: account),
                            onScheduleOverride: { slot in
                                viewModel.applyScheduleOverride(slot, for: account)
                            },
                            pollState: viewModel.pollState,
                            rateLimitSecondsRemaining: viewModel.rateLimitSecondsRemaining,
                            tokenUsageStore: viewModel.tokenUsageStore,
                            onRefresh: { await viewModel.poller?.pollNow() }
                        )
                    } else {
                        ContentUnavailableView(
                            "No Account Selected",
                            systemImage: "person.crop.circle",
                            description: Text("Select an account from the sidebar.")
                        )
                    }
                }
                .frame(minWidth: 480, minHeight: 400)
            }
        }
    }

}

private struct OnboardingContainer: View {
    let accountStore: AccountStore
    let poller: UsagePoller?
    @State private var onboardingViewModel: AccountsViewModel?
    @State private var skipped = false

    var body: some View {
        Group {
            if skipped {
                ContentUnavailableView(
                    "No Accounts Yet",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("Add an account from Settings to get started.")
                )
            } else {
                OnboardingView(
                    viewModel: onboardingViewModel ?? AccountsViewModel(accountStore: accountStore),
                    onSkip: { skipped = true }
                )
                .frame(width: 560)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if onboardingViewModel == nil {
                let vm = AccountsViewModel(accountStore: accountStore)
                vm.onAccountsAdded = { [weak poller] in
                    poller?.pollNewAccountsIfNeeded()
                }
                onboardingViewModel = vm
            }
        }
    }
}
