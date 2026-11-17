import AlarmKit
import EventKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @AppStorage("showsCalendarItems") private var showsCalendarItems = false
    @AppStorage("showsBirthdays") private var showsBirthdays = true
    @AppStorage("showsAllDayEvents") private var showsAllDayEvents = true
    @AppStorage("showsTimedEvents") private var showsTimedEvents = true
    @AppStorage("showsGroupedReminders") private var showsGroupedReminders = false
    @AppStorage("reminderHomeView") private var savedHomeView = ""
    @AppStorage("mixedExpandedFolders") private var mixedExpandedFolders = Data()
    @Environment(\.calendar) private var calendar
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Reminder.createdAt, order: .reverse) private var reminders: [Reminder]
    @Query(sort: \ReminderFolder.name) private var folders: [ReminderFolder]
    @State private var calendarStore: EKEventStore?
    @State private var todayCalendarItems: [TodayCalendarRows.CalendarItem] = []
    @State private var calendarItemsBeingCompleted: Set<String> = []
    @State private var searchText = ""
    @State private var newReminder: NewReminder?
    @State private var reminderToEdit: Reminder?
    @State private var folderToRename: ReminderFolder?
    @State private var folderName = ""
    @State private var showingNamePrompt = false
    @State private var showingSaveError = false
    @State private var showingFolderOrder = false
    @State private var showingInlineFolders = false
    @State private var showingSettings = false
    @State private var snoozedAlarmIDs: Set<UUID> = []
    @State private var remindersBeingCompleted: Set<PersistentIdentifier> = []

    private enum HomeView: String {
        case folders, grouped, mixed
    }

    private var homeView: HomeView {
        HomeView(rawValue: savedHomeView) ?? (showsGroupedReminders ? .grouped : .folders)
    }

    private var expandedFolders: Set<FolderDestination> {
        (try? JSONDecoder().decode(Set<FolderDestination>.self, from: mixedExpandedFolders)) ?? [.today]
    }

    private func expansionToggle(_ name: Text, for destination: FolderDestination) -> some View {
        Toggle(isOn: Binding {
            expandedFolders.contains(destination)
        } set: { isExpanded in
            var updated = expandedFolders
            if isExpanded {
                updated.insert(destination)
            } else {
                updated.remove(destination)
            }
            if let data = try? JSONEncoder().encode(updated) {
                mixedExpandedFolders = data
            }
        }) {
            name
        }
    }

    private var homeViewPicker: some View {
        Picker("Home View", selection: Binding(get: { homeView }, set: { savedHomeView = $0.rawValue })) {
            Label("Folder View", systemImage: "folder").tag(HomeView.folders)
            Label("Grouped List", systemImage: "list.bullet").tag(HomeView.grouped)
            Label("Mixed View", systemImage: "list.bullet.indent").tag(HomeView.mixed)
        }
    }

    private var inlineFoldersSection: some View {
        Section {
            expansionToggle(Text("Today"), for: .today)
            expansionToggle(Text("Inbox"), for: .inbox)
            ForEach(orderedFolders) { folder in
                Toggle(isOn: Binding {
                    showsInline(folder)
                } set: { isExpanded in
                    folder.showsRemindersInline = isExpanded
                    saveChanges()
                }) {
                    Text(verbatim: folder.name)
                }
            }
            expansionToggle(Text("Completed"), for: .completed)
        } footer: {
            Text("Turn on a folder to show its reminders directly on the Mixed View home screen.")
        }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                CalendarSettings(
                    isEnabled: $showsCalendarItems,
                    showsBirthdays: $showsBirthdays,
                    showsAllDayEvents: $showsAllDayEvents,
                    showsTimedEvents: $showsTimedEvents
                )
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close Settings", systemImage: "xmark") {
                        showingSettings = false
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
    }

    private var inlineFolderSettings: some View {
        NavigationStack {
            Form {
                inlineFoldersSection
            }
            .navigationTitle("Show Reminders Inline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingInlineFolders = false }
                }
            }
        }
    }

    private func showsInline(_ folder: ReminderFolder) -> Bool {
        if let preference = folder.showsRemindersInline {
            return preference
        }
        return expandedFolders.contains { destination in
            guard case let .folder(id) = destination else { return false }
            return id.id == folder.persistentModelID.id
        }
    }

    private struct NewReminder: Identifiable {
        let id = UUID()
        let folder: ReminderFolder?
        var dueDate: Date? = nil
    }

    private var trimmedFolderName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var orderedFolders: [ReminderFolder] {
        folders.sorted { ($0.sortOrder ?? Int.max) < ($1.sortOrder ?? Int.max) }
    }

    private var notificationAlerts: [ReminderNotifications.Alert] {
        reminders.compactMap(ReminderNotifications.Alert.init)
    }

    private var reminderTimeline: ExplicitTimelineSchedule<[Date]> {
        let now = Date.now
        let calendar = Calendar.current
        let upcoming = reminders.filter { !$0.isCompleted }.flatMap { reminder in
                [reminder.availableAt, reminder.earlyCompletionUnlockAt, reminder.dueDate.map { calendar.startOfDay(for: $0) }]
                .compactMap { $0 }
                .filter { $0 > now }
        }
        return .explicit([now] + Set(upcoming).sorted())
    }

    var body: some View {
        let alerts = scenePhase == .active ? notificationAlerts : nil
        NavigationStack {
            TimelineView(reminderTimeline) { _ in
                reminderList(at: .now)
            }
            .searchable(text: $searchText, prompt: "Search reminders")
            .navigationDestination(for: FolderDestination.self) { destination in
                TimelineView(reminderTimeline) { _ in
                    reminderList(at: .now, destination: destination)
                }
                .toolbar {
                    if destination != .completed && destination != .upcoming {
                        ToolbarItemGroup(placement: .bottomBar) {
                            Spacer()
                            newReminderButton {
                                switch destination {
                                case .today:
                                    newReminder = NewReminder(folder: nil, dueDate: .now)
                                case .inbox:
                                    newReminder = NewReminder(folder: nil)
                                case let .folder(id):
                                    if let folder = folders.first(where: { $0.persistentModelID == id }) {
                                        newReminder = NewReminder(folder: folder)
                                    }
                                case .completed, .upcoming:
                                    break
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Reminders")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        showingSettings = true
                    }
                    .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Reminder Options", systemImage: "ellipsis.circle") {
                        homeViewPicker
                        if homeView == .mixed {
                            Button("Show Reminders Inline", systemImage: "checklist") {
                                showingInlineFolders = true
                            }
                        }
                        Divider()
                        Button("Reorder Folders", systemImage: "arrow.up.arrow.down") {
                            showingFolderOrder = true
                        }
                        .disabled(folders.count < 2)
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        folderToRename = nil
                        folderName = ""
                        showingNamePrompt = true
                    }
                    .labelStyle(.iconOnly)

                    Spacer()

                    newReminderButton {
                        newReminder = NewReminder(folder: nil)
                    }
                }
            }
            .sheet(item: $newReminder) { request in
                ReminderEditor(initialFolder: request.folder, initialDueDate: request.dueDate)
            }
            .sheet(item: $reminderToEdit) { reminder in
                ReminderEditor(reminder: reminder)
            }
            .sheet(isPresented: $showingFolderOrder) {
                FolderOrderEditor(folders: orderedFolders)
            }
            .sheet(isPresented: $showingSettings) {
                settings
            }
            .sheet(isPresented: $showingInlineFolders) {
                inlineFolderSettings
            }
            .alert(folderToRename == nil ? "New Folder" : "Rename Folder", isPresented: $showingNamePrompt) {
                TextField("Name", text: $folderName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    guard !trimmedFolderName.isEmpty else { return }
                    if let folderToRename {
                        folderToRename.name = trimmedFolderName
                    } else {
                        modelContext.insert(ReminderFolder(name: trimmedFolderName))
                    }
                    saveChanges()
                }
                .disabled(trimmedFolderName.isEmpty)
            }
            .alert("Couldn’t Save Changes", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please try again.")
            }
        }
        .task(id: showsCalendarItems) {
            refreshTodayCalendar()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshTodayCalendar() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: RunLoop.main)) { _ in
            if scenePhase == .active { refreshTodayCalendar() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            if scenePhase == .active { refreshTodayCalendar() }
        }
        .task(id: alerts) {
            if let alerts {
                await ReminderNotifications.sync(alerts)
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { TodayWidgetUpdates.refresh(from: modelContext) }
            if #available(iOS 26.0, *), scenePhase == .active {
                let manager = AlarmManager.shared
                let updates = manager.alarmUpdates
                updateSnoozedAlarms((try? manager.alarms) ?? [])
                for await alarms in updates {
                    guard !Task.isCancelled else { break }
                    updateSnoozedAlarms(alarms)
                }
            }
        }
    }

    private func refreshTodayCalendar() {
        guard showsCalendarItems, EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            todayCalendarItems = []
            return
        }
        let store = calendarStore ?? EKEventStore()
        calendarStore = store
        todayCalendarItems = TodayCalendarRows.load(from: store, calendar: calendar)
    }

    @available(iOS 26.0, *)
    private func updateSnoozedAlarms(_ alarms: [Alarm]) {
        // Duewisp alarms use countdowns only after snoozing.
        snoozedAlarmIDs = Set(alarms.filter { $0.state == .countdown }.map(\.id))
    }

    private enum FolderDestination: Hashable, Codable {
        case today, inbox, upcoming, completed
        case folder(PersistentIdentifier)
    }

    private func reminderList(at date: Date, destination: FolderDestination? = nil) -> some View {
        let visible = reminders.filter { $0.isCompleted || ($0.availableAt ?? .distantPast) <= date }
        let calendar = Calendar.current
        let today = visible.filter { reminder in
            guard !reminder.isCompleted, let dueDate = reminder.dueDate else { return false }
            return calendar.compare(dueDate, to: date, toGranularity: .day) != .orderedDescending
        }
        let upcoming = reminders.compactMap { reminder -> (reminder: Reminder, due: Date)? in
            guard !reminder.isCompleted, let due = reminder.dueDate,
                  calendar.compare(due, to: date, toGranularity: .day) == .orderedDescending else { return nil }
            return (reminder, due)
        }
        .sorted { $0.due < $1.due }
        .map(\.reminder)
        let completed = visible.filter(\.isCompleted)
        let todayIDs = Set(today.map(\.persistentModelID))
        let remindersByFolder = Dictionary(grouping: visible) {
            $0.folder?.persistentModelID
        }
        let inbox = (remindersByFolder[nil] ?? []).filter { !todayIDs.contains($0.persistentModelID) }

        let folder: ReminderFolder?
        let title: String
        switch destination {
        case .today:
            folder = nil
            title = String(localized: "Today")
        case .inbox:
            folder = nil
            title = String(localized: "Inbox")
        case .upcoming:
            folder = nil
            title = String(localized: "Upcoming")
        case .completed:
            folder = nil
            title = String(localized: "Completed")
        case let .folder(id):
            folder = folders.first { $0.persistentModelID == id }
            title = folder?.name ?? String(localized: "Folder")
        case nil:
            folder = nil
            title = String(localized: "Reminders")
        }

        let expanded = homeView == .mixed ? expandedFolders : []

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return List {
            switch destination {
            case .today:
                todaySection(today)
            case .inbox:
                folderSections(nil, reminders: inbox)
            case .upcoming:
                if upcoming.isEmpty {
                    ContentUnavailableView("No Upcoming Reminders", systemImage: "calendar")
                } else {
                    reminderRows(upcoming, in: .upcoming)
                }
            case .completed:
                if completed.isEmpty {
                    ContentUnavailableView("No Completed Reminders", systemImage: "checkmark.circle")
                } else {
                    reminderRows(completed, in: .completed)
                }
            case let .folder(id):
                if let folder {
                    folderSections(folder, reminders: remindersByFolder[id] ?? [], todayIDs: todayIDs)
                }
            case nil where !query.isEmpty:
                let matches = reminders.filter { reminder in
                    let folderName = reminder.calendarOccurrenceID == nil
                        ? (reminder.folder?.name ?? String(localized: "Inbox"))
                        : String(localized: "Calendar")
                    return reminder.title.localizedStandardContains(query) || folderName.localizedStandardContains(query)
                }
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    reminderRows(matches, in: .search)
                }
            case nil:
                if homeView == .grouped {
                    folderSections(nil, reminders: inbox, grouped: true)
                    todaySection(today, grouped: true)
                } else if expanded.contains(.today) {
                    todaySection(today, grouped: true)
                    if expanded.contains(.inbox) {
                        folderSections(nil, reminders: inbox, grouped: true)
                    } else {
                        Section {
                            folderLink(Text("Inbox"), icon: "tray", count: inbox.filter { !$0.isCompleted }.count, destination: .inbox)
                        }
                    }
                } else {
                    Section {
                        folderLink(Text("Today"), icon: "calendar", count: today.count, destination: .today)
                        if !expanded.contains(.inbox) {
                            folderLink(Text("Inbox"), icon: "tray", count: inbox.filter { !$0.isCompleted }.count, destination: .inbox)
                        }
                    }
                    if expanded.contains(.inbox) {
                        folderSections(nil, reminders: inbox, grouped: true)
                    }
                }

                Section {
                    folderLink(Text("Upcoming"), icon: "calendar.badge.clock", count: upcoming.count, destination: .upcoming)
                }

                ForEach(orderedFolders) { folder in
                    let id = folder.persistentModelID
                    let items = remindersByFolder[id] ?? []
                    if homeView == .grouped || (homeView == .mixed && showsInline(folder)) {
                        folderSections(folder, reminders: items, todayIDs: todayIDs, grouped: true)
                    } else {
                        folderLink(Text(verbatim: folder.name), icon: "folder", count: items.filter { !$0.isCompleted }.count, destination: .folder(id))
                            .swipeActions(allowsFullSwipe: false) {
                                folderActions(for: folder)
                            }
                    }
                }

                if homeView == .grouped || expanded.contains(.completed) {
                    if homeView == .mixed || !completed.isEmpty {
                        Section {
                            folderHeader(String(localized: "Completed"), status: "\(completed.count) completed", destination: .completed)
                            reminderRows(completed, in: .completed)
                        }
                    }
                } else {
                    Section {
                        folderLink(Text("Completed"), icon: "checkmark.circle", count: completed.count, destination: .completed)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 0, for: .scrollContent)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(destination == nil ? .large : .inline)
    }

    private func folderLink(
        _ name: Text, icon: String, count: Int, destination: FolderDestination
    ) -> some View {
        NavigationLink(value: destination) {
            LabeledContent {
                Text(count, format: .number)
                    .monospacedDigit()
            } label: {
                Label { name } icon: { Image(systemName: icon) }
            }
        }
        .accessibilityLabel(name)
        .accessibilityValue(Text("Reminders: \(count)"))
    }

    private func todaySection(_ today: [Reminder], grouped: Bool = false) -> some View {
        Section {
            let name = String(localized: "Today")
            if grouped {
                folderHeader(name, status: today.isEmpty ? "All done" : "\(today.count) remaining", destination: .today)
            }
            reminderRows(today, in: .today)
            if showsCalendarItems {
                let completedIDs = Set(reminders.compactMap(\.calendarOccurrenceID))
                TodayCalendarRows(
                    items: todayCalendarItems.filter { item in
                        guard !completedIDs.contains(item.id) else { return false }
                        switch item.kind {
                        case .birthday: return showsBirthdays
                        case .allDay: return showsAllDayEvents
                        case .timed: return showsTimedEvents
                        }
                    },
                    markingIDs: calendarItemsBeingCompleted,
                    markComplete: markCalendarItemComplete
                )
            }
            if grouped {
                addReminderRow(in: name) {
                    newReminder = NewReminder(folder: nil, dueDate: .now)
                }
            }
        }
    }

    @ViewBuilder
    private func folderActions(for folder: ReminderFolder) -> some View {
        Button("Delete Folder", systemImage: "trash", role: .destructive) {
            modelContext.delete(folder)
            saveChanges()
        }
        Button("Rename Folder", systemImage: "pencil") {
            folderToRename = folder
            folderName = folder.name
            showingNamePrompt = true
        }
    }

    @ViewBuilder
    private func folderSections(
        _ folder: ReminderFolder?, reminders: [Reminder], todayIDs: Set<PersistentIdentifier> = [], grouped: Bool = false
    ) -> some View {
        let name = folder?.name ?? String(localized: "Inbox")
        let remaining = reminders.filter { !$0.isCompleted }
        let completedRepeats = reminders.filter { reminder in
            reminder.isCompleted && (reminder.repeatMode == ReminderRepeatMode.regularly.rawValue ||
                                     reminder.repeatMode == ReminderRepeatMode.afterCompletion.rawValue)
        }

        Section {
            if grouped {
                folderHeader(
                    name,
                    status: reminders.isEmpty ? "No reminders" : remaining.isEmpty ? "All done" : "\(remaining.count) remaining",
                    destination: folder.map { .folder($0.persistentModelID) } ?? .inbox
                )
                    .swipeActions(allowsFullSwipe: false) {
                        if let folder {
                            folderActions(for: folder)
                        }
                    }
            }
            reminderRows(remaining, in: .folder(folder?.persistentModelID), todayIDs: todayIDs)
            if grouped {
                addReminderRow(in: name) {
                    newReminder = NewReminder(folder: folder)
                }
            }
            if grouped && folder != nil && !completedRepeats.isEmpty {
                Text("Completed Repeats")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                reminderRows(completedRepeats, in: .folderHistory)
            }
        }

        if !grouped && folder != nil && !completedRepeats.isEmpty {
            Section("Completed Repeats") {
                reminderRows(completedRepeats, in: .folderHistory)
            }
        }
    }

    private func newReminderButton(action: @escaping () -> Void) -> some View {
        Button("New Reminder", systemImage: "plus", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
    }

    private func addReminderRow(in name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Add Reminder", systemImage: "plus")
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Add reminder to \(name)")
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    private func folderHeader(
        _ name: String, status: LocalizedStringKey, destination: FolderDestination
    ) -> some View {
        NavigationLink(value: destination) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(name)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.primary.opacity(0.045), in: Capsule())
            }
        }
    }

    private enum ReminderListSection: Hashable {
        case today, upcoming, search, completed, folderHistory
        case folder(PersistentIdentifier?)
    }

    private struct ReminderRowID: Hashable {
        let reminder: PersistentIdentifier
        let section: ReminderListSection
    }

    private func reminderRows(
        _ reminders: [Reminder], in section: ReminderListSection, todayIDs: Set<PersistentIdentifier> = []
    ) -> some View {
        let blockedOccurrences = section == .upcoming ? Reminder.laterOpenOccurrences(in: self.reminders) : []
        let today = Calendar.current.startOfDay(for: .now)
        let rows = reminders.map { reminder in
            let badge: Text?
            if reminder.calendarOccurrenceID != nil {
                badge = Text("From Calendar")
            } else if [.today, .upcoming, .search].contains(section), let folder = reminder.folder {
                badge = Text("\(Image(systemName: "folder"))\u{2009}\(folder.name)")
                    .accessibilityLabel(Text("Folder: \(folder.name)"))
            } else if todayIDs.contains(reminder.persistentModelID) {
                badge = Text("\(Image(systemName: "folder"))\u{2009}Today")
                    .accessibilityLabel(Text("Today"))
            } else {
                badge = nil
            }
            let dateText = reminder.dueDate.map { dueDate in
                reminderDateText(dueDateLabel(for: dueDate, today: today, dateOnly: reminder.isDateOnly == true), for: reminder)
            }
            return (
                id: ReminderRowID(reminder: reminder.persistentModelID, section: section),
                reminder: reminder,
                isCompleted: reminder.isCompleted,
                isOverdue: !reminder.isCompleted && reminder.dueDate.map { $0 < today } == true,
                dateText: dateText,
                badge: badge
            )
        }
        return ForEach(rows, id: \.id) { row in
            let reminder = row.reminder
            let isMarkingComplete = remindersBeingCompleted.contains(row.id.reminder)
            let isWaitingAfterEarlyCompletion = (reminder.earlyCompletionUnlockAt ?? .distantPast) > .now
            let isBlockedOccurrence = isWaitingAfterEarlyCompletion || blockedOccurrences.contains(row.id.reminder)
            let completionSymbol = isBlockedOccurrence ? "lock.circle" : (row.isCompleted || isMarkingComplete ? "checkmark.circle.fill" : "circle")
            let repeatDescription = repeatDetails(for: reminder)
            HStack(spacing: 0) {
                Button {
                    guard reminder.isCompleted else {
                        markCompleteWithFeedback(reminder)
                        return
                    }
                    withAnimation {
                        if reminder.calendarOccurrenceID != nil {
                            modelContext.delete(reminder)
                        } else {
                            reminder.reopenAsOneTime()
                        }
                        saveChanges()
                    }
                } label: {
                    Image(systemName: completionSymbol)
                        .font(.title2)
                        .foregroundStyle(isMarkingComplete ? Color.accentColor : row.isCompleted ? .secondary : .secondary.opacity(0.5))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isBlockedOccurrence)
                .accessibilityLabel(isBlockedOccurrence ? "Completion unavailable" : isMarkingComplete ? "Completing reminder" : row.isCompleted ? "Mark incomplete" : "Mark complete")
                .accessibilityHint(reminder.title)

                Button {
                    reminderToEdit = reminder
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reminder.title)
                            .foregroundStyle(row.isCompleted ? .secondary : .primary)

                        if let dateText = row.dateText {
                            dateText
                                .font(.caption)
                                .foregroundStyle(row.isOverdue ? Color.red : Color.secondary)
                        }

                        if let repeatDescription {
                            Text(repeatDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let badge = row.badge {
                            badge
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if isWaitingAfterEarlyCompletion, let unlock = reminder.earlyCompletionUnlockAt {
                            Text("Can be completed from \(unlock.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if isBlockedOccurrence {
                            Text("Complete the earlier occurrence first")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(reminder.calendarOccurrenceID != nil)
                .accessibilityHint(reminder.calendarOccurrenceID == nil ? "Edit reminder" : "")

            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
        .onDelete { offsets in
            for index in offsets {
                modelContext.delete(reminders[index])
            }
            saveChanges()
        }
    }

    private func markCalendarItemComplete(_ item: TodayCalendarRows.CalendarItem) {
        guard calendarItemsBeingCompleted.insert(item.id).inserted else { return }
        Task { @MainActor in
            defer { calendarItemsBeingCompleted.remove(item.id) }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, !reminders.contains(where: { $0.calendarOccurrenceID == item.id }) else { return }
            withAnimation(.smooth(duration: 0.3)) {
                let completion = Reminder(title: item.title, dueDate: item.date)
                completion.isDateOnly = item.kind != .timed
                completion.isCompleted = true
                completion.calendarOccurrenceID = item.id
                modelContext.insert(completion)
                saveChanges()
            }
        }
    }

    private func markCompleteWithFeedback(_ reminder: Reminder) {
        let id = reminder.persistentModelID
        guard !remindersBeingCompleted.contains(id) else { return }
        withAnimation {
            _ = remindersBeingCompleted.insert(id)
        }
        Task { @MainActor in
            defer { remindersBeingCompleted.remove(id) }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, reminder.modelContext != nil, !reminder.isDeleted, !reminder.isCompleted else { return }
            withAnimation(.smooth(duration: 0.3)) {
                reminder.complete(in: modelContext)
                saveChanges()
            }
        }
    }

    private func reminderDateText(_ dueText: String, for reminder: Reminder) -> Text {
        if #available(iOS 26.0, *), let alarmID = reminder.alarmID,
           !reminder.isCompleted, reminder.alarmStopped != true {
            if snoozedAlarmIDs.contains(alarmID) {
                return Text("\(dueText) \(Image(systemName: "alarm")) · Snoozed")
            }
            return Text("\(dueText) \(Image(systemName: "alarm"))")
        }
        return Text(dueText)
    }

    private func dueDateLabel(for dueDate: Date, today: Date, dateOnly: Bool) -> String {
        let calendar = Calendar.current
        guard dueDate < today else {
            return dueDate.formatted(date: .abbreviated, time: dateOnly ? .omitted : .shortened)
        }

        let dueDay = calendar.startOfDay(for: dueDate)
        let days = calendar.dateComponents([.day], from: today, to: dueDay)
        return RelativeDateTimeFormatter().localizedString(from: days)
    }

    private func repeatDetails(for reminder: Reminder) -> String? {
        guard let mode = ReminderRepeatMode(rawValue: reminder.repeatMode ?? ""),
              mode != .never,
              let unit = ReminderRepeatUnit(rawValue: reminder.repeatUnit ?? ""),
              let interval = reminder.repeatInterval else { return nil }

        let duration = "\(interval.formatted()) \(unit.intervalLabel(for: interval))"
        return mode == .afterCompletion
            ? "Repeats \(duration) after completion"
            : "Repeats every \(duration)"
    }

    private func saveChanges() {
        do {
            try modelContext.save()
            TodayWidgetUpdates.refresh(from: modelContext)
        } catch {
            modelContext.rollback()
            showingSaveError = true
        }
    }
}
