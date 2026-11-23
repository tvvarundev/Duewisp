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
        let changes = snapshot?.items.compactMap(\.availableAt).filter { now < $0 && $0 < tomorrow } ?? []
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
        return TodayEntry(date: date, title: name, items: items)
    }
}

private struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(entry.title, systemImage: "checklist")
                .font(.headline)
                .widgetAccentable()

            if let items = entry.items {
                if items.isEmpty {
                    Text("All clear")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ViewThatFits(in: .vertical) {
                        reminderList(items, limit: family == .systemLarge ? 8 : family == .systemMedium ? 3 : 2)
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
                let item = displayed[index]
                HStack(spacing: 8) {
                    if let id = item.id {
                        Button(intent: CompleteWidgetReminder(identifier: id)) {
                            Image(systemName: "circle")
                                .frame(minWidth: 24, minHeight: 24)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Complete \(item.title)"))
                    }
                    Text(item.title)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
            if items.count > displayed.count {
                Text("+\(items.count - displayed.count) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
