import AppIntents
#if !ALARM_ACTIVITY_EXTENSION
import SwiftData
#endif

@available(iOS 26.0, *)
struct CompleteReminderAlarm: LiveActivityIntent {
    static let title: LocalizedStringResource = "Complete Reminder"
    static let isDiscoverable = false

    @Parameter(title: "Alarm ID")
    var alarmIdentifier: String

    // Ignore retired actions on alarms that were already delivered by iOS.
    @Parameter(title: "Put On Hold", default: false)
    var putOnHold: Bool

    @Parameter(title: "Keep Snoozing", default: false)
    var keepSnoozing: Bool

    @Parameter(title: "End Snooze", default: false)
    var endSnooze: Bool

    init() {}

    init(alarmID: UUID, stopAlarm: Bool = false) {
        alarmIdentifier = alarmID.uuidString
        self.putOnHold = false
        keepSnoozing = false
        self.endSnooze = stopAlarm
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !ALARM_ACTIVITY_EXTENSION
        guard !putOnHold, !keepSnoozing, let alarmID = UUID(uuidString: alarmIdentifier) else { return .result() }
        let context = try DuewispApp.storage.get().mainContext
        let activeReminders = FetchDescriptor<Reminder>(predicate: #Predicate { !$0.isCompleted })
        let reminders = try context.fetch(activeReminders)
        guard let reminder = reminders.first(where: { $0.alarmID == alarmID }) else { return .result() }
        if endSnooze {
            reminder.alarmStopped = true
        } else {
            reminder.complete(in: context)
        }
        do {
            try context.save()
            TodayWidgetUpdates.refresh(from: context)
        } catch {
            context.rollback()
            throw error
        }
        let updatedReminders = try context.fetch(activeReminders)
        await ReminderNotifications.sync(updatedReminders.compactMap(ReminderNotifications.Alert.init))
        #endif
        return .result()
    }
}
