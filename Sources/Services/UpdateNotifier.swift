import AppKit
@preconcurrency import UserNotifications

/// Posts a user notification when a new Clusage version is available. Clicking the
/// notification opens the Settings window so the user can install it.
@MainActor
enum UpdateNotifier {
    nonisolated static let category = "studio.seventwo.clusage.update"
    nonisolated static let installAction = "studio.seventwo.clusage.update.install"

    static func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationDelegate.shared

        let install = UNNotificationAction(
            identifier: installAction,
            title: "View in Settings",
            options: [.foreground]
        )
        let cat = UNNotificationCategory(
            identifier: category,
            actions: [install],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([cat])
    }

    static func notify(version: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.update.error("Notification auth error: \(error.localizedDescription)")
            }
            guard granted else {
                Log.update.info("Notifications not authorized; skipping update notice")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Clusage \(version) available"
            content.body = "A new version is ready to install."
            content.categoryIdentifier = category
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "clusage.update.\(version)",
                content: content,
                trigger: nil
            )
            center.add(request) { err in
                if let err {
                    Log.update.error("Notification add error: \(err.localizedDescription)")
                } else {
                    Log.update.info("Posted update notification for \(version)")
                }
            }
        }
    }

    private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        static let shared = NotificationDelegate()

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound])
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping @Sendable () -> Void
        ) {
            Task { @MainActor in
                NSApp.activate()
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            completionHandler()
        }
    }
}
