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
            let items = try context.fetch(query).compactMap { reminder -> TodayWidgetSnapshot.Item? in
                guard let dueDate = reminder.dueDate else { return nil }
                return .init(title: reminder.title, dueDate: dueDate, availableAt: reminder.availableAt)
            }
            let previous = try? JSONDecoder().decode(TodayWidgetSnapshot.self, from: Data(contentsOf: url))
            let snapshot = TodayWidgetSnapshot(items: items)
            guard previous != snapshot else { return }
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: TodayWidgetSnapshot.kind)
        } catch {
            Logger(subsystem: "com.duewisp.app", category: "Widget")
                .error("Could not refresh the Today widget: \(error.localizedDescription, privacy: .private)")
        }
    }
}
