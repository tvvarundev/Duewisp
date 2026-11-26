import Foundation
import AppIntents
#if !ALARM_ACTIVITY_EXTENSION
import SwiftData
import UIKit
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
        let activeReminders = FetchDescriptor<Reminder>(predicate: #Predicate { !$0.isCompleted && $0.deletedAt == nil })
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
        let groupedAlarms = try context.fetch(FetchDescriptor<AlarmGroup>()).flatMap(\.schedule)
        await ReminderNotifications.sync(
            updatedReminders.compactMap(ReminderNotifications.Alert.init),
            groupedAlarms: groupedAlarms
        )
        #endif
        return .result()
    }
}

struct CompleteWidgetReminder: LiveActivityIntent {
    static let title: LocalizedStringResource = "Complete Reminder"
    static let isDiscoverable = false
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: ExecutionTargets { .main }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Reminder")
    var identifier: String

    @Parameter(title: "Calendar Event", default: false)
    var isCalendarEvent: Bool

    init() {}

    init(identifier: String, isCalendarEvent: Bool = false) {
        self.identifier = identifier
        self.isCalendarEvent = isCalendarEvent
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if ALARM_ACTIVITY_EXTENSION
        try rejectExtensionExecution()
        #else
        let context = try DuewispApp.storage.get().mainContext
        if isCalendarEvent {
            try completeCalendarEvent(in: context)
            return .result()
        }
        let query = FetchDescriptor<Reminder>(predicate: #Predicate { !$0.isCompleted && $0.deletedAt == nil })
        let now = Date.now
        guard let data = Data(base64Encoded: identifier),
              let id = try? JSONDecoder().decode(PersistentIdentifier.self, from: data),
              let reminder = try context.fetch(query).first(where: { $0.persistentModelID.id == id.id }),
              (reminder.availableAt ?? .distantPast) <= now,
              (reminder.completionUnlockAt ?? .distantPast) <= now else {
            TodayWidgetUpdates.refresh(from: context)
            return .result()
        }
        let changesAlerts = ReminderNotifications.Alert(reminder) != nil ||
            (reminder.repeatMode != nil && reminder.isDateOnly != true)
        reminder.complete(in: context, at: now)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        TodayWidgetUpdates.refresh(from: context)
        guard changesAlerts else { return .result() }
        let alerts = try context.fetch(query).compactMap(ReminderNotifications.Alert.init)
        let groups = try context.fetch(FetchDescriptor<AlarmGroup>()).flatMap(\.schedule)
        let application = UIApplication.shared
        var backgroundID = UIBackgroundTaskIdentifier.invalid
        func finishBackgroundTask() {
            guard backgroundID != .invalid else { return }
            application.endBackgroundTask(backgroundID)
            backgroundID = .invalid
        }
        backgroundID = application.beginBackgroundTask(withName: "Update reminder alerts") {
            finishBackgroundTask()
        }
        if backgroundID == .invalid {
            await ReminderNotifications.sync(alerts, groupedAlarms: groups, requestPermission: false)
        } else {
            Task { @MainActor in
                defer { finishBackgroundTask() }
                await ReminderNotifications.sync(alerts, groupedAlarms: groups, requestPermission: false)
            }
        }
        #endif
        return .result()
    }

    #if !ALARM_ACTIVITY_EXTENSION
    @MainActor
    private func completeCalendarEvent(in context: ModelContext) throws {
        let now = Date.now
        guard let event = TodayWidgetSnapshot.read()?.dueItems(at: now).first(where: {
            $0.calendarDay != nil && $0.id == identifier
        }) else {
            TodayWidgetUpdates.refresh(from: context)
            return
        }

        let eventID = identifier
        var existing = FetchDescriptor<Reminder>(
            predicate: #Predicate { $0.calendarOccurrenceID == eventID && $0.deletedAt == nil }
        )
        existing.fetchLimit = 1
        if try context.fetch(existing).isEmpty {
            let completion = Reminder(title: event.title, dueDate: event.dueDate ?? event.calendarDay)
            completion.calendarOccurrenceID = eventID
            completion.isDateOnly = event.isDateOnly ?? true
            context.insert(completion)
            completion.complete(in: context, at: now)
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
        TodayWidgetUpdates.refresh(from: context)
    }
    #endif

    #if ALARM_ACTIVITY_EXTENSION
    private func rejectExtensionExecution() throws {
        throw CocoaError(.featureUnsupported)
    }
    #endif
}
