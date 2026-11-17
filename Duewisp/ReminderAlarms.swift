import AlarmKit
import OSLog
import SwiftUI

@available(iOS 26.0, *)
@MainActor
enum ReminderAlarms {
    private static let logger = Logger(subsystem: "com.duewisp.app", category: "Alarms")
    private static let stopIntentIDsKey = "alarmIDsWithTimedSnooze"

    static func sync(_ alerts: [ReminderNotifications.Alert]) async -> Set<UUID> {
        let manager = AlarmManager.shared
        var desiredMinutes: [UUID: Int] = [:]
        for alert in alerts {
            if let id = alert.alarmID {
                desiredMinutes[id] = alert.snoozeMinutes
            }
        }
        var scheduledIDs: Set<UUID> = []

        do {
            let upcoming = alerts.filter { $0.alarmID != nil && $0.date > .now }
            if manager.authorizationState == .notDetermined && !upcoming.isEmpty {
                _ = try await manager.requestAuthorization()
            }
            guard !Task.isCancelled, manager.authorizationState == .authorized else { return [] }

            let previousIDs = Set(UserDefaults.standard.stringArray(forKey: stopIntentIDsKey) ?? [])
            var stopIntentIDs: Set<String> = []
            for alarm in try manager.alarms {
                let hasStopIntent = previousIDs.contains(alarm.id.uuidString)
                if let minutes = desiredMinutes[alarm.id],
                   alarm.state != .scheduled || (hasStopIntent && alarm.countdownDuration == countdown(for: minutes)) {
                    scheduledIDs.insert(alarm.id)
                    if hasStopIntent { stopIntentIDs.insert(alarm.id.uuidString) }
                } else {
                    do {
                        try manager.cancel(id: alarm.id)
                    } catch {
                        if hasStopIntent { stopIntentIDs.insert(alarm.id.uuidString) }
                        if desiredMinutes[alarm.id] != nil {
                            scheduledIDs.insert(alarm.id)
                        }
                        logger.error("Could not cancel reminder alarm: \(error.localizedDescription, privacy: .private)")
                    }
                }
            }

            for item in upcoming {
                guard !Task.isCancelled else { break }
                guard let id = item.alarmID, !scheduledIDs.contains(id), item.date > .now else { continue }
                do {
                    try await schedule(id: id, title: item.title, date: item.date, snoozeMinutes: item.snoozeMinutes)
                    scheduledIDs.insert(id)
                    stopIntentIDs.insert(id.uuidString)
                } catch {
                    logger.error("Could not schedule reminder alarm: \(error.localizedDescription, privacy: .private)")
                }
            }
            if stopIntentIDs != previousIDs {
                UserDefaults.standard.set(stopIntentIDs.sorted(), forKey: stopIntentIDsKey)
            }
        } catch {
            logger.error("Could not reconcile reminder alarms: \(error.localizedDescription, privacy: .private)")
        }
        return scheduledIDs
    }

    private static func schedule(id: UUID, title: String, date: Date, snoozeMinutes: Int) async throws {
        let localizedTitle = LocalizedStringResource(stringLiteral: title)
        let duration = countdown(for: snoozeMinutes)
        let snooze = duration.map { _ in AlarmButton(text: "Snooze", textColor: .white, systemImageName: "alarm") }
        let behavior: AlarmPresentation.Alert.SecondaryButtonBehavior? = snooze == nil ? nil : .countdown
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = .init(title: localizedTitle, secondaryButton: snooze, secondaryButtonBehavior: behavior)
        } else {
            alert = .init(title: localizedTitle, stopButton: AlarmButton(
                text: "Complete", textColor: .white, systemImageName: "checkmark"
            ), secondaryButton: snooze, secondaryButtonBehavior: behavior)
        }
        let attributes = AlarmAttributes<ReminderAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert, countdown: duration == nil ? nil : .init(title: localizedTitle)),
            tintColor: .accentColor
        )
        _ = try await AlarmManager.shared.schedule(id: id, configuration: .init(
            countdownDuration: duration, schedule: .fixed(date), attributes: attributes,
            stopIntent: CompleteReminderAlarm(alarmID: id)
        ))
    }

    private static func countdown(for minutes: Int) -> Alarm.CountdownDuration? {
        guard minutes > 0 else { return nil }
        return .init(preAlert: nil, postAlert: TimeInterval(minutes) * 60)
    }
}
