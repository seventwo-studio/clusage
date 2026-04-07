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

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: MenuBarViewModel(
                accountStore: accountStore,
                poller: poller,
                momentumProvider: momentumProvider
            ))
            .onAppear {
                Log.app.info("Menu bar popover appeared")
                if accountStore.accounts.isEmpty {
                    Log.app.info("No accounts — opening dashboard for onboarding")
                    openWindow(id: "dashboard")
                }
            }
        } label: {
            MenuBarIcon(accountStore: accountStore)
            .task {
                recordStartupGap()
                accountStore.refreshAllFromKeychain()
                tokenUsageStore.refresh()
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
            DashboardView(
                viewModel: DashboardViewModel(
                    accountStore: accountStore,
                    historyStore: historyStore,
                    streakStore: streakStore,
                    momentumProvider: momentumProvider,
                    poller: poller,
                    tokenUsageStore: tokenUsageStore
                )
            )
            .onAppear {
                Log.app.info("Dashboard window opened")
                NSApp.activate()
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
        guard quitTimestamp > 0 else {
            Log.app.info("App started — no previous quit time recorded (first launch)")
            return
        }
        let quitDate = Date(timeIntervalSince1970: quitTimestamp)
        let gap = MonitoringGap(start: quitDate, end: Date())
        historyStore.addGap(gap)
        historyStore.saveGaps()
        Log.app.info("App started — recorded gap since quit: \(String(format: "%.0f", Date().timeIntervalSince(quitDate)))s")
        // Remove quit key AND update lastPollAt so the poller doesn't record a duplicate gap
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.lastQuitAt)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: DefaultsKeys.lastPollAt)
    }

    @State private var terminationObserver: NSObjectProtocol?

    private func observeAppLifecycle() {
        guard terminationObserver == nil else { return }
        let pollerRef = poller
        let historyRef = historyStore
        let streakRef = streakStore
        let tokenRef = tokenUsageStore
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            Log.app.info("App terminating — stopping poller and saving state")
            pollerRef?.stop()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: DefaultsKeys.lastQuitAt)
            historyRef.save()
            historyRef.saveGaps()
            streakRef.save()
            tokenRef.save()
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
    }
}
