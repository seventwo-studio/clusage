import AppKit
import SwiftUI

@main
struct ClusageApp: App {
    @State private var accountStore = AccountStore()
    @State private var historyStore = UsageHistoryStore()
    @State private var streakStore = StreakStore()
    @State private var tokenUsageStore = TokenUsageStore()
    @State private var momentumProvider: MomentumProvider?
    @State private var poller: UsagePoller?
    @State private var updateChecker = UpdateChecker()
    @State private var hotkeyManager = HotkeyManager()
    @State private var menuBarViewModel: MenuBarViewModel?
    @State private var dashboardViewModel: DashboardViewModel?

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            if let menuBarViewModel {
                MenuBarView(viewModel: menuBarViewModel)
            }
        } label: {
            MenuBarIcon(accountStore: accountStore)
            .onAppear {
                if menuBarViewModel == nil {
                    menuBarViewModel = MenuBarViewModel(accountStore: accountStore)
                    dashboardViewModel = DashboardViewModel(
                        accountStore: accountStore,
                        historyStore: historyStore
                    )
                }
                if accountStore.accounts.isEmpty {
                    Log.app.info("No accounts — opening dashboard for onboarding")
                    openWindow(id: "dashboard")
                }
            }
            .task {
                recordStartupGap()
                accountStore.refreshAllFromKeychain()
                tokenUsageStore.refresh()
                tokenUsageStore.refreshSessions()
                startPolling()
                observeAppLifecycle()
                updateChecker.startIfEnabled()
                hotkeyManager.start { [openWindow] in
                    openWindow(id: "dashboard")
                    NSApp.activate()
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Dashboard", id: "dashboard") {
            if let dashboardViewModel {
                DashboardView(viewModel: dashboardViewModel)
            }
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView(
                accountStore: accountStore,
                momentumProvider: momentumProvider,
                historyStore: historyStore,
                streakStore: streakStore,
                poller: poller,
                updateChecker: updateChecker,
                hotkeyManager: hotkeyManager
            )
            .frame(width: 480, height: 700)
        }
    }

    private func recordStartupGap() {
        let quitTimestamp = UserDefaults.standard.double(forKey: DefaultsKeys.lastQuitAt)
        if quitTimestamp > 0 {
            let quitDate = Date(timeIntervalSince1970: quitTimestamp)
            let gap = MonitoringGap(start: quitDate, end: Date())
            historyStore.addGap(gap)
            historyStore.saveGaps()
            Log.app.info("App started — recorded gap since quit: \(String(format: "%.0f", Date().timeIntervalSince(quitDate)))s")
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.lastQuitAt)
        } else {
            Log.app.info("App started — no previous quit time recorded (first launch)")
        }
        // Always update lastPollAt so the poller doesn't record a duplicate gap
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: DefaultsKeys.lastPollAt)
    }

    @State private var terminationObserver: NSObjectProtocol?

    private func observeAppLifecycle() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [self] _ in
            Log.app.info("App terminating — stopping poller and saving state")
            poller?.stop()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: DefaultsKeys.lastQuitAt)
            historyStore.save()
            historyStore.saveGaps()
            streakStore.save()
            tokenUsageStore.save()
        }
    }

    private func startPolling() {
        guard poller == nil else { return }
        Log.app.info("Creating and starting poller")

        let provider = MomentumProvider(
            historyStore: historyStore,
            streakStore: streakStore,
            accountStore: accountStore
        )
        provider.refresh()
        momentumProvider = provider

        let newPoller = UsagePoller(
            accountStore: accountStore,
            historyStore: historyStore,
            momentumProvider: provider,
            tokenUsageStore: tokenUsageStore
        )
        poller = newPoller
        newPoller.start()

        // Update ViewModels with the now-available services
        menuBarViewModel?.poller = newPoller
        menuBarViewModel?.momentumProvider = provider
        dashboardViewModel?.poller = newPoller
        dashboardViewModel?.momentumProvider = provider
        dashboardViewModel?.streakStore = streakStore
        dashboardViewModel?.tokenUsageStore = tokenUsageStore
    }
}
