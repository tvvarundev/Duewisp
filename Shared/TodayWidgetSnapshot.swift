import Foundation

struct TodayWidgetSnapshot: Codable, Equatable {
    static let kind = "DuewispToday"
    private static let group = "group.com.duewisp.app"
    private static let filename = "today-widget.json"

    struct Item: Codable, Equatable {
        let title: String
        var id: String? = nil
        var folderID: String? = nil
        let dueDate: Date?
        let availableAt: Date?
        var completionUnlockAt: Date? = nil
        var isDateOnly: Bool? = nil
        var hasAlarm: Bool? = nil
        var calendarDay: Date? = nil
    }

    struct Folder: Codable, Equatable {
        let id: String
        let name: String
    }

    var folders: [Folder]? = nil
    let items: [Item]
    var calendarItems: [Item]? = nil
    var completedCalendarIDs: [String]? = nil

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent(filename)
    }

    static func read() -> Self? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func dueItems(at date: Date, calendar: Calendar = .current) -> [Item] {
        let reminders = items.filter {
            ($0.availableAt ?? .distantPast) <= date &&
                $0.dueDate.map { calendar.compare($0, to: date, toGranularity: .day) != .orderedDescending } == true
        }
        let completedIDs = Set(completedCalendarIDs ?? [])
        let events = (calendarItems ?? []).filter { item in
            guard let day = item.calendarDay, let id = item.id else { return false }
            return calendar.isDate(day, inSameDayAs: date) && !completedIDs.contains(id)
        }
        return reminders + events
    }
}
