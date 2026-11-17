import Foundation
import SwiftData

@Model
final class Reminder {
    static let defaultSnoozeMinutes = 30
    static let snoozeOff = -1

    var title: String
    var dueDate: Date?
    var isDateOnly: Bool?
    var isCompleted = false
    var calendarOccurrenceID: String?
    var createdAt = Date.now
    var folder: ReminderFolder?
    var repeatMode: String?
    var repeatUnit: String?
    var repeatInterval: Int?
    var repeatAnchor: Date?
    var repeatStartDate: Date?
    var repeatEndDate: Date?
    var hasScheduledNextOccurrence: Bool?
    var scheduledOccurrenceID: UUID?
    var generatedOccurrenceID: UUID?
    var generatedOccurrenceWasEdited: Bool?
    var availableAt: Date?
    var earlyCompletionUnlockAt: Date?
    var alarmID: UUID?
    var alarmStopped: Bool?
    var alarmSnoozeMinutes: Int?

    var snoozeMinutes: Int {
        guard let alarmSnoozeMinutes, alarmSnoozeMinutes > 0 || alarmSnoozeMinutes == Self.snoozeOff
        else { return Self.defaultSnoozeMinutes }
        return alarmSnoozeMinutes
    }

    init(title: String, dueDate: Date?) {
        self.title = title
        self.dueDate = dueDate
    }

    func complete(in modelContext: ModelContext, at completedAt: Date = .now) {
        guard !isCompleted, (earlyCompletionUnlockAt ?? .distantPast) <= completedAt else { return }
        isCompleted = true
        guard hasScheduledNextOccurrence != true,
              let mode = ReminderRepeatMode(rawValue: repeatMode ?? ""),
              let unit = ReminderRepeatUnit(rawValue: repeatUnit ?? ""),
              let interval = repeatInterval else { return }

        let anchor = repeatAnchor ?? dueDate ?? createdAt
        guard let nextDate = mode.nextDate(
            dueDate: dueDate, anchor: anchor, completedAt: completedAt, interval: interval, unit: unit,
            endsOn: repeatEndDate
        ) else { return }

        let next = Reminder(title: title, dueDate: nextDate)
        next.isDateOnly = isDateOnly
        next.availableAt = nextDate
        if let dueDate, dueDate > completedAt {
            next.earlyCompletionUnlockAt = min(dueDate, nextDate)
        }
        if alarmID != nil {
            next.alarmID = UUID()
            next.alarmSnoozeMinutes = snoozeMinutes
        }
        next.folder = folder
        next.repeatMode = mode.rawValue
        next.repeatUnit = unit.rawValue
        next.repeatInterval = interval
        next.repeatAnchor = anchor
        next.repeatStartDate = repeatStartDate
        next.repeatEndDate = repeatEndDate
        let occurrenceID = UUID()
        next.generatedOccurrenceID = occurrenceID
        scheduledOccurrenceID = occurrenceID
        modelContext.insert(next)
        hasScheduledNextOccurrence = true
    }

    func reopenAsOneTime() {
        isCompleted = false
        availableAt = nil
        earlyCompletionUnlockAt = nil
        repeatMode = nil
        repeatUnit = nil
        repeatInterval = nil
        repeatAnchor = nil
        repeatStartDate = nil
        repeatEndDate = nil
        hasScheduledNextOccurrence = nil
        scheduledOccurrenceID = nil
        if generatedOccurrenceID != nil {
            generatedOccurrenceWasEdited = true
        }
    }

    static func laterOpenOccurrences(in reminders: [Reminder]) -> Set<PersistentIdentifier> {
        let successors = Dictionary(grouping: reminders, by: \.generatedOccurrenceID)
        var blocked: Set<PersistentIdentifier> = []
        for reminder in reminders where !reminder.isCompleted && reminder.repeatMode != nil {
            var visited: Set<UUID> = []
            var nextID = reminder.scheduledOccurrenceID
            while let id = nextID, visited.insert(id).inserted, let next = successors[id]?.first {
                if !next.isCompleted && next.repeatMode != nil {
                    blocked.insert(next.persistentModelID)
                }
                nextID = next.scheduledOccurrenceID
            }
        }
        return blocked
    }

    func undoCompletion(in modelContext: ModelContext, snoozedAlarmIDs: Set<UUID>) throws -> Bool {
        guard isCompleted else { return true }
        if hasScheduledNextOccurrence == true {
            guard let scheduledOccurrenceID else { return false }
            let candidates = FetchDescriptor<Reminder>(predicate: #Predicate {
                $0.generatedOccurrenceID == scheduledOccurrenceID
            })
            guard let next = try modelContext.fetch(candidates).first,
                  !next.isCompleted, next.generatedOccurrenceWasEdited != true,
                  next.alarmStopped != true,
                  next.alarmID.map({ !snoozedAlarmIDs.contains($0) }) ?? true else { return false }
            modelContext.delete(next)
            hasScheduledNextOccurrence = nil
            self.scheduledOccurrenceID = nil
        }
        isCompleted = false
        return true
    }
}

enum ReminderRepeatMode: String, CaseIterable {
    case never = "Never"
    case regularly = "Repeat Regularly"
    case afterCompletion = "Repeat After Completion"

    func nextDate(
        dueDate: Date?, anchor: Date, completedAt: Date,
        interval: Int, unit: ReminderRepeatUnit, endsOn: Date? = nil,
        calendar: Calendar = .current
    ) -> Date? {
        guard (1...99).contains(interval) else { return nil }
        switch self {
        case .never:
            return nil
        case .afterCompletion:
            guard let day = calendar.date(byAdding: unit.component, value: interval, to: completedAt)
            else { return nil }
            guard let dueDate else { return day }
            let time = calendar.dateComponents([.hour, .minute], from: dueDate)
            return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day)
        case .regularly:
            let threshold = max(dueDate ?? completedAt, completedAt)
            let elapsed = calendar.dateComponents([unit.component], from: anchor, to: threshold)
                .value(for: unit.component) ?? 0
            let offset = max(0, elapsed / interval * interval)
            guard let candidate = calendar.date(byAdding: unit.component, value: offset, to: anchor)
            else { return nil }
            let next = candidate > threshold
                ? candidate
                : calendar.date(byAdding: unit.component, value: offset + interval, to: anchor)
            if let endsOn, let next,
               calendar.compare(next, to: endsOn, toGranularity: .day) == .orderedDescending {
                return nil
            }
            return next
        }
    }
}

enum ReminderRepeatUnit: String, CaseIterable {
    case days = "Days"
    case weeks = "Weeks"
    case months = "Months"
    case years = "Years"

    func intervalLabel(for count: Int) -> String {
        guard count == 1 else { return rawValue.lowercased() }
        switch self {
        case .days: return "day"
        case .weeks: return "week"
        case .months: return "month"
        case .years: return "year"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .days: .day
        case .weeks: .weekOfYear
        case .months: .month
        case .years: .year
        }
    }
}

@Model
final class ReminderFolder {
    var name: String
    var sortOrder: Int?
    var showsRemindersInline: Bool?

    @Relationship(deleteRule: .nullify, inverse: \Reminder.folder)
    var reminders: [Reminder] = []

    init(name: String) {
        self.name = name
    }
}
