import Foundation
import OSLog
import SwiftData
import WidgetKit

enum TodayWidgetUpdates {
    @MainActor
    static func recordCompletion(
        id: String, isCalendarEvent: Bool, from context: ModelContext
    ) {
        guard let url = TodayWidgetSnapshot.fileURL,
              var snapshot = TodayWidgetSnapshot.read() else {
            refresh(from: context, reloadTimeline: false)
            return
        }

        if isCalendarEvent {
            var completedIDs = Set(snapshot.completedCalendarIDs ?? [])
            guard completedIDs.insert(id).inserted else { return }
            snapshot.completedCalendarIDs = completedIDs.sorted()
        } else {
            guard let index = snapshot.items.firstIndex(where: { $0.id == id }) else {
                refresh(from: context, reloadTimeline: false)
                return
            }
            snapshot.items.remove(at: index)
        }

        do {
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {
            refresh(from: context, reloadTimeline: false)
        }
    }

    @MainActor
    static func refresh(
        from context: ModelContext,
        calendarItems: [TodayWidgetSnapshot.Item]? = nil,
        reloadTimeline: Bool = true
    ) {
        guard let url = TodayWidgetSnapshot.fileURL else { return }

        do {
            let query = FetchDescriptor<Reminder>(
                predicate: #Predicate { !$0.isCompleted && $0.deletedAt == nil },
                sortBy: [SortDescriptor(\Reminder.dueDate), SortDescriptor(\Reminder.createdAt)]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let items = try context.fetch(query).map { reminder in
                TodayWidgetSnapshot.Item(
                    title: reminder.title,
                    id: try encoder.encode(reminder.persistentModelID).base64EncodedString(),
                    folderID: try reminder.folder.map { try encoder.encode($0.persistentModelID).base64EncodedString() },
                    dueDate: reminder.dueDate,
                    availableAt: reminder.availableAt,
                    completionUnlockAt: reminder.completionUnlockAt,
                    isDateOnly: reminder.isDateOnly == true,
                    hasAlarm: reminder.alarmID != nil && reminder.alarmStopped != true
                )
            }
            let folders = try context.fetch(FetchDescriptor<ReminderFolder>(sortBy: [SortDescriptor(\.name)])).map {
                TodayWidgetSnapshot.Folder(id: try encoder.encode($0.persistentModelID).base64EncodedString(), name: $0.name)
            }
            let previous = TodayWidgetSnapshot.read()
            let events = calendarItems ?? previous?.calendarItems ?? []
            let eventIDs = Set(events.compactMap(\.id))
            var completedIDs: [String] = []
            if !eventIDs.isEmpty {
                let completions = FetchDescriptor<Reminder>(
                    predicate: #Predicate { $0.calendarOccurrenceID != nil && $0.deletedAt == nil }
                )
                completedIDs = Set(try context.fetch(completions).compactMap(\.calendarOccurrenceID))
                    .intersection(eventIDs).sorted()
            }
            let snapshot = TodayWidgetSnapshot(
                folders: folders,
                items: items,
                calendarItems: events.isEmpty ? nil : events,
                completedCalendarIDs: completedIDs.isEmpty ? nil : completedIDs
            )
            guard previous != snapshot else { return }
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            if reloadTimeline { WidgetCenter.shared.reloadTimelines(ofKind: TodayWidgetSnapshot.kind) }
        } catch {
            Logger(subsystem: "com.duewisp.app", category: "Widget")
                .error("Could not refresh the Today widget: \(error.localizedDescription, privacy: .private)")
        }
    }
}
