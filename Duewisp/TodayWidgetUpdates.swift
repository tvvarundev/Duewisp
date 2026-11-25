import Foundation
import OSLog
import SwiftData
import WidgetKit

enum TodayWidgetUpdates {
    @MainActor
    static func refresh(from context: ModelContext) {
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
            let snapshot = TodayWidgetSnapshot(folders: folders, items: items)
            guard previous != snapshot else { return }
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: TodayWidgetSnapshot.kind)
        } catch {
            Logger(subsystem: "com.duewisp.app", category: "Widget")
                .error("Could not refresh the Today widget: \(error.localizedDescription, privacy: .private)")
        }
    }
}
