import Foundation
import OSLog
import SwiftData
import UserNotifications

enum ReminderNotifications {
    struct Alert: Equatable {
        let id: PersistentIdentifier
        let title: String
        let date: Date
        let alarmID: UUID?
        let snoozeMinutes: Int

        init?(_ reminder: Reminder) {
            guard !reminder.isCompleted, reminder.alarmStopped != true, reminder.isDateOnly != true, let date = reminder.dueDate else { return nil }
            id = reminder.persistentModelID
            title = reminder.title
            self.date = date
            alarmID = reminder.alarmID
            snoozeMinutes = reminder.snoozeMinutes
        }
    }

    private static let prefix = "duewisp.reminder."
    private static let logger = Logger(subsystem: "com.duewisp.app", category: "Notifications")
    @MainActor private static var pendingSync: Task<Void, Never>?

    @MainActor
    static func sync(_ alerts: [Alert]) async {
        let previous = pendingSync
        previous?.cancel()
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }

            let scheduledAlarms: Set<UUID>
            if #available(iOS 26.0, *) {
                scheduledAlarms = await ReminderAlarms.sync(alerts)
            } else {
                scheduledAlarms = []
            }
            guard !Task.isCancelled else { return }
            let notifications = alerts.filter { alert in
                guard let alarmID = alert.alarmID else { return true }
                return !scheduledAlarms.contains(alarmID)
            }
            await syncNotifications(notifications)
        }
        pendingSync = task
        await task.value
    }

    @MainActor
    private static func syncNotifications(_ alerts: [Alert]) async {
        let center = UNUserNotificationCenter.current()
        let now = Date.now
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let upcoming = alerts.filter { $0.date > now }.sorted { $0.date < $1.date }
            .prefix(64).compactMap { alert -> (String, Alert)? in
                guard let encodedID = try? encoder.encode(alert.id) else { return nil }
                return (prefix + encodedID.base64EncodedString(), alert)
            }
        let pending = await center.pendingNotificationRequests()
        guard !Task.isCancelled else { return }

        let existing = pending.filter { $0.identifier.hasPrefix(prefix) }
        let identifiers = Set(upcoming.map { $0.0 })
        center.removePendingNotificationRequests(
            withIdentifiers: existing.map(\.identifier).filter { !identifiers.contains($0) }
        )
        guard !upcoming.isEmpty else { return }

        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]),
                  !Task.isCancelled else { return }

            let requests = Dictionary(uniqueKeysWithValues: existing.map { ($0.identifier, $0) })
            for (identifier, alert) in upcoming {
                guard !Task.isCancelled else { return }
                guard alert.date > .now else { continue }
                let calendar = Calendar.current
                let fireDate = Date(timeIntervalSince1970: alert.date.timeIntervalSince1970.rounded(.up))
                let date = calendar.dateComponents(
                    [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
                    from: fireDate
                )
                if let request = requests[identifier],
                   request.content.title == alert.title,
                   (request.trigger as? UNCalendarNotificationTrigger)?.dateComponents == date {
                    continue
                }

                let content = UNMutableNotificationContent()
                content.title = alert.title
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: false)
                do {
                    try await center.add(UNNotificationRequest(
                        identifier: identifier, content: content, trigger: trigger
                    ))
                } catch {
                    logger.error("Could not schedule reminder alert: \(error.localizedDescription, privacy: .private)")
                }
            }
        } catch {
            logger.error("Could not request notification permission: \(error.localizedDescription, privacy: .private)")
        }
    }
}
