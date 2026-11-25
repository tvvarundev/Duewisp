import AppIntents
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
        AppIntentConfiguration(kind: TodayWidgetSnapshot.kind, intent: ReminderWidgetSettings.self, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Duewisp Today")
        .description("See reminders due today or overdue.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ReminderWidgetSettings: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Reminder Folder"

    @Parameter(title: "Folder")
    var folder: WidgetReminderFolder?
}

struct WidgetReminderFolder: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Folder"
    static let defaultQuery = WidgetReminderFolderQuery()

    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WidgetReminderFolderQuery: EntityQuery {
    func suggestedEntities() async throws -> [WidgetReminderFolder] {
        [WidgetReminderFolder(id: "today", name: String(localized: "Today")),
         WidgetReminderFolder(id: "inbox", name: String(localized: "Inbox"))]
            + (TodayWidgetSnapshot.read()?.folders ?? []).map { WidgetReminderFolder(id: $0.id, name: $0.name) }
    }

    func entities(for identifiers: [String]) async throws -> [WidgetReminderFolder] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
}

private struct TodayEntry: TimelineEntry {
    let date: Date
    var title = String(localized: "Today")
    var symbol = "calendar"
    let items: [TodayWidgetSnapshot.Item]?
}

private struct TodayProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        let now = Date.now
        return TodayEntry(date: now, items: [
            .init(title: String(localized: "Review the budget"), dueDate: now, availableAt: nil),
            .init(title: String(localized: "Call the dentist"), dueDate: now, availableAt: nil)
        ])
    }

    func snapshot(for configuration: ReminderWidgetSettings, in context: Context) async -> TodayEntry {
        context.isPreview ? placeholder(in: context) : entry(at: .now, snapshot: TodayWidgetSnapshot.read(), folder: configuration.folder)
    }

    func timeline(for configuration: ReminderWidgetSettings, in context: Context) async -> Timeline<TodayEntry> {
        let now = Date.now
        let snapshot = TodayWidgetSnapshot.read()
        let calendar = Calendar.current
        let tomorrow = calendar.dateInterval(of: .day, for: now)?.end ?? now.addingTimeInterval(86400)
        let changes = snapshot?.items.flatMap { item in
            [item.availableAt, item.completionUnlockAt].compactMap { $0 }
        }.filter { now < $0 && $0 < tomorrow } ?? []
        let dates = [now] + Set(changes).sorted()
        return Timeline(entries: dates.map { entry(at: $0, snapshot: snapshot, folder: configuration.folder) }, policy: .after(tomorrow))
    }

    private func entry(at date: Date, snapshot: TodayWidgetSnapshot?, folder: WidgetReminderFolder?) -> TodayEntry {
        guard let folder, folder.id != "today" else {
            return TodayEntry(date: date, items: snapshot?.dueItems(at: date))
        }
        let items = snapshot?.items.filter {
            ($0.availableAt ?? .distantPast) <= date &&
                (folder.id == "inbox" ? $0.folderID == nil : $0.folderID == folder.id)
        }
        let name = snapshot?.folders?.first { $0.id == folder.id }?.name ?? folder.name
        return TodayEntry(date: date, title: name, symbol: folder.id == "inbox" ? "tray" : "folder", items: items)
    }
}

private struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry
    private let minimumRowHeight: CGFloat = 28
    private var rowSpacing: CGFloat { family == .systemMedium ? 2 : 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 4 : 8) {
            HStack(spacing: 6) {
                Label(entry.title, systemImage: entry.symbol)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let count = entry.items?.count, count > 0 {
                    Text(count, format: .number)
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .accessibilityLabel(Text("\(count) remaining"))
                        .privacySensitive()
                }
            }
            .foregroundStyle(Color("ReminderAccent"))
            .widgetAccentable()

            if let items = entry.items {
                if items.isEmpty {
                    Text("All clear")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    GeometryReader { space in
                        let maxRows = max(1, Int((space.size.height + rowSpacing) / (minimumRowHeight + rowSpacing)))
                        let counts = (1...min(items.count, maxRows)).reversed()
                        ViewThatFits(in: .vertical) {
                            ForEach(counts, id: \.self) { count in
                                reminderList(items, limit: count)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("\(items.count) reminders")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .privacySensitive()
                }
            } else {
                Text("Open Duewisp to load reminders")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func reminderList(_ items: [TodayWidgetSnapshot.Item], limit: Int) -> some View {
        let displayed = items.prefix(limit)
        return VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(displayed.indices, id: \.self) { index in
                let item = displayed[index]
                HStack(spacing: 8) {
                    if let unlock = item.completionUnlockAt, unlock > entry.date {
                        Image(systemName: "lock.circle")
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 28)
                            .accessibilityLabel(Text("Completion available at \(unlock.formatted())"))
                    } else if let id = item.id {
                        Toggle(isOn: false, intent: CompleteWidgetReminder(identifier: id)) {
                            Text("Complete \(item.title)")
                        }
                        .toggleStyle(ReminderChecklistToggleStyle(title: item.title))
                        .id(id)
                    }
                    reminderText(item)
                }
                .frame(minHeight: minimumRowHeight)
            }
        }
    }

    private func reminderText(_ item: TodayWidgetSnapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 0 : 2) {
            Text(item.title)
                .font((family == .systemMedium ? Font.footnote : .subheadline).weight(.medium))
                .lineLimit(family == .systemLarge ? 2 : 1)
            if let due = item.dueDate {
                dueDetails(item, due: due)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func dueDetails(_ item: TodayWidgetSnapshot.Item, due: Date) -> some View {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: entry.date),
                                           to: calendar.startOfDay(for: due)).day ?? 0
        let day: String
        switch days {
        case ..<0: day = RelativeDateTimeFormatter().localizedString(from: DateComponents(day: days))
        case 0: day = String(localized: "Today")
        case 1: day = String(localized: "Tomorrow")
        default: day = due.formatted(date: .abbreviated, time: .omitted)
        }
        let showsTime = item.isDateOnly == false
        let time = due.formatted(date: .omitted, time: .shortened)
        return HStack(spacing: 3) {
            Text(day)
            if showsTime {
                if item.hasAlarm == true {
                    Image(systemName: "alarm")
                        .accessibilityLabel("Alarm")
                } else {
                    Text("·").accessibilityHidden(true)
                }
                Text(time)
            }
        }
        .font(.caption2)
        .foregroundStyle(days < 0 ? Color.red : Color.secondary)
        .lineLimit(1)
    }

}

private struct ReminderChecklistToggleStyle: ToggleStyle {
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var circleSize = 22.0

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: circleSize, weight: .light))
                .foregroundStyle(configuration.isOn ? Color("ReminderAccent") : Color.secondary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(minWidth: 44, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .default, value: configuration.isOn)
        .accessibilityLabel(Text("Complete \(title)"))
    }
}
