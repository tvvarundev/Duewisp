import Foundation

struct TodayWidgetSnapshot: Codable, Equatable {
    static let kind = "DuewispToday"
    private static let group = "group.com.duewisp.app"
    private static let filename = "today-widget.json"

    struct Item: Codable, Equatable {
        let title: String
        let dueDate: Date
        let availableAt: Date?
    }

    let items: [Item]

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent(filename)
    }

    func dueItems(at date: Date, calendar: Calendar = .current) -> [Item] {
        items.filter {
            ($0.availableAt ?? .distantPast) <= date &&
                calendar.compare($0.dueDate, to: date, toGranularity: .day) != .orderedDescending
        }
    }
}
