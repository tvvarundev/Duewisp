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
                .widgetURL(entry.folderURL)
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
    static var today: Self { Self(id: "today", name: String(localized: "Today")) }

    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WidgetReminderFolderQuery: EntityQuery {
    func defaultResult() async -> WidgetReminderFolder? { .today }

    func suggestedEntities() async throws -> [WidgetReminderFolder] {
        [WidgetReminderFolder.today,
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
    var folderID = "today"
    let items: [TodayWidgetSnapshot.Item]?

    var folderURL: URL? {
        var components = URLComponents()
        components.scheme = "duewisp"
        components.host = "folder"
        components.queryItems = [URLQueryItem(name: "id", value: folderID)]
        return components.url
    }
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
        return TodayEntry(date: date, title: name, symbol: folder.id == "inbox" ? "tray" : "folder", folderID: folder.id, items: items)
    }
}

private struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: TodayEntry
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 22
    private let iconSpacing: CGFloat = 8
    private var headerSpacing: CGFloat { family == .systemSmall ? 4 : 6 }
    @ScaledMetric(relativeTo: .footnote) private var rowSpacing: CGFloat = 10

    private var checklistRowLimit: Int {
        switch family {
        case .systemSmall, .systemMedium: dynamicTypeSize.isAccessibilitySize ? 1 : 3
        case .systemLarge: dynamicTypeSize.isAccessibilitySize ? 3 : 8
        default: .max
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let items = entry.items, !items.isEmpty {
                GeometryReader { space in
                    let maxRows = max(1, Int(space.size.height / iconWidth))
                    let counts = (1...min(maxRows, checklistRowLimit)).reversed()
                    let fittedSpacing = (space.size.height / CGFloat(checklistRowLimit) - iconWidth).rounded(.down)
                    let spacing = dynamicTypeSize.isAccessibilitySize ? rowSpacing : max(rowSpacing, fittedSpacing)
                    ViewThatFits(in: .vertical) {
                        ForEach(counts, id: \.self) { count in
                            reminderList(items, limit: count, spacing: spacing)
                        }
                        Text("\(items.count) reminders")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, headerSpacing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 4)
            } else if entry.items == nil {
                Text("Open Duewisp to load reminders")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, headerSpacing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if entry.items?.isEmpty == true {
                Text("All clear")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var header: some View {
        HStack(spacing: iconSpacing) {
            Image(systemName: entry.symbol)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(entry.title)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let count = entry.items?.count, count > 0 {
                Text(count, format: .number)
                    .monospacedDigit()
                    .accessibilityLabel(Text("\(count) remaining"))
                    .privacySensitive()
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color("ReminderAccent"))
        .widgetAccentable()
    }

    private func reminderList(_ items: [TodayWidgetSnapshot.Item], limit: Int, spacing: CGFloat) -> some View {
        let displayed = items.prefix(limit).enumerated().map { index, item in
            (key: item.calendarDay != nil ? "calendar-\(item.id ?? "")" : item.id ?? "preview-\(index)", item: item)
        }
        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(displayed, id: \.key) { row in
                let item = row.item
                HStack(spacing: iconSpacing) {
                    if let unlock = item.completionUnlockAt, unlock > entry.date {
                        Image(systemName: "lock.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: iconWidth, height: iconWidth)
                            .accessibilityLabel(Text("Completion available at \(unlock.formatted())"))
                    } else if let id = item.id {
                        Toggle(isOn: false, intent: CompleteWidgetReminder(identifier: id, isCalendarEvent: item.calendarDay != nil)) {
                            Text("Complete \(item.title)")
                        }
                        .toggleStyle(ReminderChecklistToggleStyle(title: item.title, circleSize: iconWidth))
                        .id(id)
                    }
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.footnote)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if family != .systemSmall, item.calendarDay == nil, let dueDate = item.dueDate {
                            let calendar = Calendar.current
                            let overdueDays = calendar.dateComponents(
                                [.day],
                                from: calendar.startOfDay(for: dueDate),
                                to: calendar.startOfDay(for: entry.date)
                            ).day ?? 0
                            if overdueDays > 0 {
                                Text("\(overdueDays)d ago")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .accessibilityLabel(Text(RelativeDateTimeFormatter().localizedString(
                                        from: DateComponents(day: -overdueDays)
                                    )))
                            }
                        }
                        if item.calendarDay != nil {
                            Image(systemName: "calendar")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("From Calendar")
                        } else if item.hasAlarm == true {
                            Image(systemName: "alarm")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Alarm")
                        }
                    }
                }
                .frame(minHeight: iconWidth)
                .fixedSize(horizontal: false, vertical: true)
                .privacySensitive()
                .transition(.opacity)
            }
        }
        .padding(.top, spacing)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ReminderChecklistToggleStyle: ToggleStyle {
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let circleSize: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: circleSize, weight: .light))
                .foregroundStyle(configuration.isOn ? Color("ReminderAccent") : Color(uiColor: .systemGray3))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: circleSize, height: circleSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .default, value: configuration.isOn)
        .accessibilityLabel(Text("Complete \(title)"))
    }
}
