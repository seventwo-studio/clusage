import Foundation

enum DefaultsKeys {
    // MARK: - Accounts

    static let accounts = "clusage.accounts"
    static let menuBarAccountID = "clusage.menuBarAccountID"

    // MARK: - Polling

    static let pollingActiveInterval = "clusage.polling.activeInterval"
    static let pollingNormalInterval = "clusage.polling.normalInterval"
    static let pollingIdleInterval = "clusage.polling.idleInterval"
    static let pollingRateLimitEvents = "clusage.polling.rateLimitEvents"

    // MARK: - Poller State

    static let rateLimitExpiresAt = "clusage.poller.rateLimitExpiresAt"
    static let lastPollAt = "clusage.poller.lastPollAt"

    // MARK: - App Lifecycle

    static let lastQuitAt = "clusage.lastQuitAt"

    // MARK: - Updates

    static let lastUpdateCheck = "clusage.update.lastCheck"
    static let skipVersion = "clusage.update.skipVersion"
    static let autoCheckUpdates = "clusage.update.autoCheck"
    static let lastNotifiedVersion = "clusage.update.lastNotifiedVersion"

    // MARK: - Keyboard Shortcut

    static let dashboardHotkeyModifiers = "clusage.hotkey.modifiers"
    static let dashboardHotkeyKeyCode = "clusage.hotkey.keyCode"
}
