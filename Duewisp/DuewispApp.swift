import SwiftData
import SwiftUI
import UserNotifications

@main
struct DuewispApp: App {
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var notificationDelegate
    static let storage = Result {
        // The widget reads a snapshot. Keep existing reminders in the app's original store.
        try ModelContainer(for: Reminder.self, ReminderFolder.self, configurations: ModelConfiguration(groupContainer: .none))
    }

    var body: some Scene {
        WindowGroup {
            switch Self.storage {
            case .success(let container):
                ContentView()
                    .modelContainer(container)
            case .failure:
                ContentUnavailableView("Couldn’t Open Reminders", systemImage: "exclamationmark.circle")
            }
        }
    }
}

final class NotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
