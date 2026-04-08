import Foundation

@MainActor @Observable
final class MenuBarViewModel {
    let accountStore: AccountStore
    var poller: UsagePoller?
    var momentumProvider: MomentumProvider?

    init(accountStore: AccountStore, poller: UsagePoller? = nil, momentumProvider: MomentumProvider? = nil) {
        self.accountStore = accountStore
        self.poller = poller
        self.momentumProvider = momentumProvider
    }

    var accounts: [Account] {
        accountStore.accounts
    }

    var hasAccounts: Bool {
        !accounts.isEmpty
    }

    var selectedAccount: Account? {
        accountStore.menuBarAccount
    }

    var selectedAccountID: UUID? {
        get { accountStore.menuBarAccount?.id }
        set { accountStore.menuBarAccountID = newValue }
    }

    var momentum: MomentumCalculation? {
        guard let id = selectedAccount?.id else { return nil }
        return momentumProvider?.momentum(for: id)
    }

    var streak: UsageStreak? {
        guard let id = selectedAccount?.id else { return nil }
        return momentumProvider?.streak(for: id)
    }

    var projection: WindowProjection? {
        guard let id = selectedAccount?.id else { return nil }
        return momentumProvider?.projection(for: id)
    }

    var dailyTarget: BudgetEngine.DailyTarget? {
        guard let id = selectedAccount?.id else { return nil }
        return momentumProvider?.dailyTarget(for: id)
    }
}
