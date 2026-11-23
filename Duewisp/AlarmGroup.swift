import Foundation
import SwiftData

@Model
final class AlarmGroup {
    var name: String
    var isEnabled: Bool
    var dateEnabled: Bool?
    var repeatDays: [Int]?

    @Relationship(deleteRule: .cascade, inverse: \GroupedAlarm.group)
    var alarms: [GroupedAlarm] = []

    init(name: String) {
        self.name = name
        isEnabled = true
    }

    var schedule: [ScheduledAlarm] {
        guard isEnabled else { return [] }
        return alarms.filter(\.isEnabled).map { ScheduledAlarm(id: $0.id, title: name, date: $0.date, weekdays: repeatDays ?? []) }
    }

    struct ScheduledAlarm: Equatable {
        let id: UUID
        let title: String
        let date: Date
        let weekdays: [Int]
    }

    func update(name: String, times: [(date: Date, isEnabled: Bool)], weekdays: [Int] = [], dateEnabled: Bool = true, in context: ModelContext) {
        let existing = self.name == name && (repeatDays ?? []) == weekdays
            ? Dictionary(alarms.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
            : [:]
        let updated = times.map { time in
            let alarm = existing[time.date] ?? GroupedAlarm(date: time.date)
            if existing[time.date] == nil { context.insert(alarm) }
            alarm.isEnabled = time.isEnabled
            return alarm
        }
        let updatedIDs = Set(updated.map(\.id))
        for alarm in alarms where !updatedIDs.contains(alarm.id) {
            context.delete(alarm)
        }
        self.name = name
        self.dateEnabled = dateEnabled
        repeatDays = weekdays
        alarms = updated
    }
}

@Model
final class GroupedAlarm {
    var id: UUID
    var date: Date
    private var isDisabled: Bool?
    var group: AlarmGroup?

    init(date: Date) {
        id = UUID()
        self.date = date
    }

    var isEnabled: Bool {
        get { isDisabled != true }
        set { isDisabled = newValue ? nil : true }
    }
}
