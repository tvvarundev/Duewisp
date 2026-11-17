import SwiftUI
import WidgetKit

@main
struct DuewispWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        if #available(iOS 26, *) {
            AlarmActivity()
        }
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TodayWidgetSnapshot.kind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Duewisp Today")
        .description("See reminders due today or overdue.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct TodayEntry: TimelineEntry {
    let date: Date
    let items: [TodayWidgetSnapshot.Item]?
}

private struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        let now = Date.now
        return TodayEntry(date: now, items: [
            .init(title: String(localized: "Review the budget"), dueDate: now, availableAt: nil),
            .init(title: String(localized: "Call the dentist"), dueDate: now, availableAt: nil)
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(at: .now, snapshot: readSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date.now
        let snapshot = readSnapshot()
        let calendar = Calendar.current
        let tomorrow = calendar.dateInterval(of: .day, for: now)?.end ?? now.addingTimeInterval(86400)
        let availabilityChanges = snapshot?.items.compactMap { item -> Date? in
            guard let availableAt = item.availableAt, availableAt > now, availableAt < tomorrow,
                  item.dueDate < tomorrow else { return nil }
            return availableAt
        } ?? []
        let dates = [now] + Set(availabilityChanges).sorted() + [tomorrow]
        let nextRefresh = calendar.dateInterval(of: .day, for: tomorrow)?.end ?? tomorrow.addingTimeInterval(86400)
        completion(Timeline(entries: dates.map { entry(at: $0, snapshot: snapshot) }, policy: .after(nextRefresh)))
    }

    private func readSnapshot() -> TodayWidgetSnapshot? {
        guard let url = TodayWidgetSnapshot.fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TodayWidgetSnapshot.self, from: data)
    }

    private func entry(at date: Date, snapshot: TodayWidgetSnapshot?) -> TodayEntry {
        TodayEntry(date: date, items: snapshot?.dueItems(at: date))
    }
}

private struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Today", systemImage: "checklist")
                .font(.headline)
                .widgetAccentable()

            if let items = entry.items {
                if items.isEmpty {
                    Text("All clear")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ViewThatFits(in: .vertical) {
                        reminderList(items, limit: family == .systemSmall ? 2 : 3)
                        reminderList(items, limit: 1)
                        Text("\(items.count) due")
                            .foregroundStyle(.secondary)
                    }
                    .privacySensitive()
                }
            } else {
                Text("Open Duewisp to load reminders")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func reminderList(_ items: [TodayWidgetSnapshot.Item], limit: Int) -> some View {
        let displayed = items.prefix(limit)
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(displayed.indices, id: \.self) { index in
                Text(displayed[index].title)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            if items.count > displayed.count {
                Text("+\(items.count - displayed.count) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
