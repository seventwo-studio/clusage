import Foundation

enum ResetService {
    /// Clear all usage data (snapshots, gaps, streaks, calibration) while keeping accounts.
    @MainActor static func resetUsageData(
        accountStore: AccountStore,
        historyStore: UsageHistoryStore?,
        streakStore: StreakStore?,
        momentumProvider: MomentumProvider?
    ) {
        historyStore?.clearAll()
        streakStore?.clearAll()
        momentumProvider?.ratioCalibrationStore.clearAll()
        momentumProvider?.clearCalculations()
        PollingSettings.clearRateLimitHistory()

        for account in accountStore.accounts {
            var cleared = account
            cleared.fiveHour = nil
            cleared.sevenDay = nil
            cleared.lastUpdated = nil
            cleared.lastError = nil
            accountStore.updateAccount(cleared)
        }

        let ud = UserDefaults.standard
        ud.removeObject(forKey: DefaultsKeys.rateLimitExpiresAt)
        ud.removeObject(forKey: DefaultsKeys.lastPollAt)
        ud.removeObject(forKey: DefaultsKeys.lastQuitAt)
        Log.app.info("Usage data reset (accounts kept)")
    }

    /// Full factory reset — removes all data including accounts and settings.
    @MainActor static func fullReset(
        accountStore: AccountStore,
        historyStore: UsageHistoryStore?,
        streakStore: StreakStore?,
        momentumProvider: MomentumProvider?
    ) {
        resetUsageData(
            accountStore: accountStore,
            historyStore: historyStore,
            streakStore: streakStore,
            momentumProvider: momentumProvider
        )
        PollingSettings.resetToDefaults()
        accountStore.removeAllAccounts()
        let ud = UserDefaults.standard
        ud.removeObject(forKey: DefaultsKeys.menuBarAccountID)
        Log.app.info("Full reset completed")
    }
}
