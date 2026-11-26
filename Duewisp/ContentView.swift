import AlarmKit
import EventKit
import SwiftData
import SwiftUI
import UIKit

struct ContentView: View {
    @AppStorage("showsCalendarItems") private var showsCalendarItems = false
    @AppStorage("showsBirthdays") private var showsBirthdays = true
    @AppStorage("showsAllDayEvents") private var showsAllDayEvents = true
    @AppStorage("showsTimedEvents") private var showsTimedEvents = true
    @AppStorage("showsGroupedReminders") private var showsGroupedReminders = false
    @AppStorage("reminderHomeView") private var savedHomeView = ""
    @AppStorage("homeFolderOrder") private var homeFolderOrder = Data()
    @AppStorage("mixedExpandedFolders") private var mixedExpandedFolders = Data()
    @Environment(\.calendar) private var calendar
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Reminder> { $0.deletedAt == nil }, sort: \Reminder.createdAt, order: .reverse) private var reminders: [Reminder]
    @Query(filter: #Predicate<Reminder> { $0.deletedAt != nil }, sort: \Reminder.deletedAt, order: .reverse) private var deletedReminders: [Reminder]
    @Query(sort: \ReminderFolder.name) private var folders: [ReminderFolder]
    @Query(sort: \AlarmGroup.name) private var alarmGroups: [AlarmGroup]
    @State private var selectedTab: AppTab = .reminders
    @State private var tabBeforeSearch: AppTab = .reminders
    @State private var scheduledAlarmIDs: Set<UUID>?
    @State private var isAlarmPermissionDenied = false
    @State private var calendarStore: EKEventStore?
    @State private var todayCalendarItems: [TodayCalendarRows.CalendarItem] = []
    @State private var calendarItemsBeingCompleted: Set<String> = []
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var openedFolder: FolderDestination?
    @State private var pendingWidgetFolder: FolderDestination?
    @State private var reminderEditMode: EditMode = .inactive
    @State private var selectedReminderRows: Set<ReminderRowID> = []
    @State private var pendingDeletionIDs: Set<PersistentIdentifier>?
    @State private var reminderEditorRequest: ReminderEditorRequest?
    @State private var folderToRename: ReminderFolder?
    @State private var folderName = ""
    @State private var showingNamePrompt = false
    @State private var showingSaveError = false
    @State private var showingFolderOrder = false
    @State private var showingInlineFolders = false
    @State private var showingSettings = false
    @State private var snoozedAlarmIDs: Set<UUID> = []
    @State private var remindersBeingCompleted: Set<PersistentIdentifier> = []

    private var isSelectingReminders: Bool {
        reminderEditMode.isEditing || !selectedReminderRows.isEmpty
    }

    private var selectionTitle: String {
        let count = Set(selectedReminderRows.map(\.reminder)).count
        return count == 0 ? String(localized: "Select Reminders") : String(localized: "\(count) Selected")
    }

    private enum AppTab: Hashable {
        case reminders, alarms, search
    }

    private struct AlarmSchedule: Equatable {
        let reminders: [ReminderNotifications.Alert]
        let groupedAlarms: [AlarmGroup.ScheduledAlarm]
    }

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

    private struct ReminderEditorRequest: Identifiable {
        let id = UUID()
        var reminder: Reminder? = nil
        var folder: ReminderFolder? = nil
        var dueDate: Date? = nil
    }

    private var trimmedFolderName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var orderedFolders: [ReminderFolder] {
        folders.sorted { ($0.sortOrder ?? Int.max) < ($1.sortOrder ?? Int.max) }
    }

    private var orderedDestinations: [FolderDestination] {
        let first: [FolderDestination] = homeView == .grouped
            ? [.inbox, .today] : [.today, .inbox]
        var missing = first + [.upcoming] + orderedFolders.map { .folder($0.persistentModelID) } + [.completed, .deleted]
        let saved = (try? JSONDecoder().decode([FolderDestination].self, from: homeFolderOrder)) ?? []
        // Decoded SwiftData identifiers can compare equal to live identifiers while hashing differently.
        var order = saved.compactMap { destination -> FolderDestination? in
            guard let index = missing.firstIndex(where: { destination == $0 }) else { return nil }
            return missing.remove(at: index)
        }
        let insertion = order.firstIndex { $0 == .completed || $0 == .deleted } ?? order.endIndex
        order.insert(contentsOf: missing, at: insertion)
        return order
    }

    private var alarmSchedule: AlarmSchedule {
        AlarmSchedule(
            reminders: reminders.compactMap(ReminderNotifications.Alert.init),
            groupedAlarms: alarmGroups.flatMap(\.schedule).sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    private var reminderTimeline: ExplicitTimelineSchedule<[Date]> {
        let now = Date.now
        let calendar = Calendar.current
        let upcoming = reminders.filter { !$0.isCompleted }.flatMap { reminder in
                [reminder.availableAt, reminder.completionUnlockAt, reminder.dueDate.map { calendar.startOfDay(for: $0) }]
                .compactMap { $0 }
                .filter { $0 > now }
        }
        return .explicit([now] + Set(upcoming).sorted())
    }

    var body: some View {
        let schedule = scenePhase == .active ? alarmSchedule : nil
        tabs
        .onOpenURL(perform: openWidgetFolder)
        .task(id: scenePhase == .active ? pendingWidgetFolder : nil) {
            guard scenePhase == .active, let destination = pendingWidgetFolder else { return }
            // Let the Home Screen launch transition settle before pushing the folder.
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled, pendingWidgetFolder == destination else { return }
            pendingWidgetFolder = nil
            guard selectedTab == .reminders, openedFolder == nil else { return }
            withAnimation { openedFolder = destination }
        }
        .sheet(item: $reminderEditorRequest) { request in
            ReminderEditor(reminder: request.reminder, initialFolder: request.folder, initialDueDate: request.dueDate)
                .id(request.id)
        }
        .onChange(of: selectedTab) { _, tab in
            if tab != .search { tabBeforeSearch = tab }
            isSearchPresented = tab == .search
        }
        .onChange(of: isSearchPresented) { _, isPresented in
            if !isPresented && selectedTab == .search {
                selectedTab = tabBeforeSearch
            }
        }
        .onChange(of: openedFolder) {
            pendingDeletionIDs = nil
            reminderEditMode = .inactive
            selectedReminderRows.removeAll()
        }
        .onChange(of: homeView) {
            reminderEditMode = .inactive
            selectedReminderRows.removeAll()
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
        .task(id: schedule) {
            if let schedule {
                await ReminderNotifications.sync(schedule.reminders, groupedAlarms: schedule.groupedAlarms)
                if #available(iOS 26.0, *), !Task.isCancelled {
                    updateSystemAlarms((try? AlarmManager.shared.alarms) ?? [])
                }
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { TodayWidgetUpdates.refresh(from: modelContext) }
            if #available(iOS 26.0, *), scenePhase == .active {
                let manager = AlarmManager.shared
                let updates = manager.alarmUpdates
                updateSystemAlarms((try? manager.alarms) ?? [])
                for await alarms in updates {
                    guard !Task.isCancelled else { break }
                    updateSystemAlarms(alarms)
                }
            }
        }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $selectedTab) {
                Tab("Reminders", systemImage: "checklist", value: .reminders) { reminderNavigation }
                Tab("Alarms", systemImage: "alarm", value: .alarms) { alarmGroupsScreen }
                Tab(value: .search, role: .search) { searchNavigation }
            }
        } else {
            TabView(selection: $selectedTab) {
                reminderNavigation
                    .tabItem { Label("Reminders", systemImage: "checklist") }
                    .tag(AppTab.reminders)
                alarmGroupsScreen
                    .tabItem { Label("Alarms", systemImage: "alarm") }
                    .tag(AppTab.alarms)
                searchNavigation
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(AppTab.search)
            }
        }
    }

    private var reminderNavigation: some View {
        NavigationStack { reminderHome }
    }

    private var alarmGroupsScreen: some View {
        AlarmGroupsView(groups: alarmGroups, scheduledIDs: scheduledAlarmIDs, isPermissionDenied: isAlarmPermissionDenied)
    }

    private var searchNavigation: some View {
        NavigationStack {
            searchResults
                .searchable(text: $searchText, isPresented: $isSearchPresented, prompt: "Search reminders")
        }
    }

    private var searchResults: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? [] : reminders.filter { reminder in
            let folderName = reminder.calendarOccurrenceID == nil
                ? (reminder.folder?.name ?? String(localized: "Inbox"))
                : String(localized: "Calendar")
            return reminder.title.localizedStandardContains(query) || folderName.localizedStandardContains(query)
        }
        return List {
            if query.isEmpty {
                ContentUnavailableView("Search Reminders", systemImage: "magnifyingglass")
                    .listRowBackground(Color.clear)
            } else if matches.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            } else {
                reminderRows(matches, in: .search)
            }
        }
        .listStyle(.insetGrouped)
        .modifier(ReminderListBounds())
        .navigationTitle("Search")
        .alert("Couldn’t Save Changes", isPresented: $showingSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try again.")
        }
    }

    private var reminderHome: some View {
        TimelineView(reminderTimeline) { _ in
            reminderList(at: .now)
        }
        .navigationDestination(item: $openedFolder) { destination in
            TimelineView(reminderTimeline) { _ in
                reminderList(at: .now, destination: destination)
            }
            .navigationTitle(isSelectingReminders ? selectionTitle : name(for: destination))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { reminderToolbar(for: destination) }
        }
        .navigationTitle(isSelectingReminders ? selectionTitle : String(localized: "Reminders"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            reminderToolbar(for: nil)
            if !isSelectingReminders {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Reminder Options", systemImage: "ellipsis.circle") {
                        Button("Add Folder", systemImage: "folder.badge.plus") {
                            folderToRename = nil
                            folderName = ""
                            showingNamePrompt = true
                        }
                        Button("Settings", systemImage: "gearshape") {
                            showingSettings = true
                        }
                        Divider()
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
                    }
                }
            }
        }
        .sheet(isPresented: $showingFolderOrder) {
            FolderOrderEditor(folders: orderedDestinations, name: name(for:)) { order in
                if let encoded = try? JSONEncoder().encode(order) {
                    homeFolderOrder = encoded
                }
            }
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
    private func updateSystemAlarms(_ alarms: [Alarm]) {
        scheduledAlarmIDs = Set(alarms.map(\.id))
        isAlarmPermissionDenied = AlarmManager.shared.authorizationState == .denied
        // Duewisp alarms use countdowns only after snoozing.
        snoozedAlarmIDs = Set(alarms.filter { $0.state == .countdown }.map(\.id))
    }

    private func openWidgetFolder(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "duewisp", components.host == "folder",
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value else { return }

        let destination: FolderDestination?
        switch id {
        case "today":
            destination = .today
        case "inbox":
            destination = .inbox
        default:
            guard let data = Data(base64Encoded: id),
                  let identifier = try? JSONDecoder().decode(PersistentIdentifier.self, from: data) else { return }
            destination = folders.first { $0.persistentModelID.id == identifier.id }
                .map { .folder($0.persistentModelID) }
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        let alreadyOpen = openedFolder == destination
        withTransaction(transaction) {
            selectedTab = .reminders
            if !alreadyOpen { openedFolder = nil }
        }
        pendingWidgetFolder = alreadyOpen ? nil : destination
    }

    private enum FolderDestination: Hashable, Codable {
        case today, inbox, upcoming, completed, deleted
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
        let completed = visible.filter(\.isCompleted).sorted(by: Reminder.completedMoreRecently)
        let todayIDs = Set(today.map(\.persistentModelID))
        let remindersByFolder = Dictionary(grouping: reminders) {
            $0.folder?.persistentModelID
        }
        let inbox = visible.filter { $0.folder == nil && !todayIDs.contains($0.persistentModelID) }

        let expanded = homeView == .mixed ? expandedFolders : []

        let isVisibleList = destination == openedFolder
        let canSelectReminders = isVisibleList && destination != .deleted && (destination != nil || homeView != .folders)
        let selection = Binding<Set<ReminderRowID>>(
            get: { selectedReminderRows },
            set: { rows in
                guard reminderEditMode.isEditing else { return }
                selectedReminderRows = rows
                if !rows.isEmpty && reminderEditMode != .active {
                    withAnimation { reminderEditMode = .active }
                }
            }
        )
        return List(selection: canSelectReminders ? selection : nil) {
            switch destination {
            case .today:
                todaySection(today)
            case .inbox:
                folderSections(nil, reminders: inbox, at: date)
            case .upcoming:
                if upcoming.isEmpty {
                    ContentUnavailableView("No Upcoming Reminders", systemImage: "calendar")
                        .listRowBackground(Color.clear)
                } else {
                    reminderRows(upcoming, in: .upcoming)
                }
            case .deleted:
                if deletedReminders.isEmpty {
                    ContentUnavailableView("No Deleted Reminders", systemImage: "trash")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(deletedReminders) { reminder in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reminder.title)
                            if let deletedAt = reminder.deletedAt {
                                Text("Deleted \(deletedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            case .completed:
                if completed.isEmpty {
                    ContentUnavailableView("No Completed Reminders", systemImage: "checkmark.circle")
                        .listRowBackground(Color.clear)
                } else {
                    reminderRows(completed, in: .completed)
                }
            case let .folder(id):
                if let folder = folders.first(where: { $0.persistentModelID == id }) {
                    folderSections(folder, reminders: remindersByFolder[id] ?? [], at: date, todayIDs: todayIDs)
                }
            case nil:
                ForEach(orderedDestinations, id: \.self) { folderDestination in
                    switch folderDestination {
                    case .inbox:
                        if homeView == .grouped || expanded.contains(.inbox) {
                            folderSections(nil, reminders: inbox, at: date, grouped: true)
                        } else {
                            Section {
                                folderLink(Text("Inbox"), icon: "tray", count: inbox.filter { !$0.isCompleted }.count, destination: .inbox)
                            }
                        }
                    case .today:
                        if homeView == .grouped || expanded.contains(.today) {
                            todaySection(today, grouped: true)
                        } else {
                            Section {
                                folderLink(Text("Today"), icon: "calendar", count: today.count, destination: .today)
                            }
                        }
                    case .upcoming:
                        Section {
                            folderLink(Text("Upcoming"), icon: "calendar.badge.clock", count: upcoming.count, destination: .upcoming)
                        }
                    case .folder(let id):
                        if let folder = folders.first(where: { $0.persistentModelID == id }) {
                            let items = remindersByFolder[id] ?? []
                            if homeView == .grouped || (homeView == .mixed && showsInline(folder)) {
                                folderSections(folder, reminders: items, at: date, todayIDs: todayIDs, grouped: true)
                            } else {
                                folderLink(Text(verbatim: folder.name), icon: "folder", count: items.filter { !$0.isCompleted }.count, destination: .folder(id))
                                    .swipeActions(allowsFullSwipe: false) {
                                        folderActions(for: folder)
                                    }
                            }
                        }
                    case .completed:
                        if (homeView == .grouped || expanded.contains(.completed)) && !completed.isEmpty {
                            Section {
                                folderHeader(String(localized: "Completed"), status: "\(completed.count) completed", destination: .completed)
                                reminderRows(completed, in: .completed)
                            }
                        } else {
                            Section {
                                folderLink(Text("Completed"), icon: "checkmark.circle", count: completed.count, destination: .completed)
                            }
                        }
                    case .deleted:
                        Section {
                            folderLink(Text("Deleted"), icon: "trash", count: deletedReminders.count, destination: .deleted)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .modifier(ReminderListBounds())
        .contentMargins(.top, 0, for: .scrollContent)
        .environment(\.editMode, isVisibleList ? $reminderEditMode : .constant(.inactive))
        .animation(.default, value: canSelectReminders && reminderEditMode.isEditing)
        .alert("Delete selected reminders?", isPresented: Binding(
            get: { openedFolder == destination && pendingDeletionIDs != nil },
            set: { if !$0 && openedFolder == destination { pendingDeletionIDs = nil } }
        ), presenting: pendingDeletionIDs) { ids in
            Button("Delete", role: .destructive) {
                deleteSelectedReminders(ids)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn’t Save Changes", isPresented: Binding(
            get: { selectedTab == .reminders && openedFolder == destination && showingSaveError },
            set: { if selectedTab == .reminders && openedFolder == destination { showingSaveError = $0 } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try again.")
        }
    }

    private func name(for destination: FolderDestination) -> String {
        switch destination {
        case .today: String(localized: "Today")
        case .inbox: String(localized: "Inbox")
        case .upcoming: String(localized: "Upcoming")
        case .deleted: String(localized: "Deleted")
        case .completed: String(localized: "Completed")
        case let .folder(id):
            folders.first { $0.persistentModelID == id }?.name ?? String(localized: "Folder")
        }
    }

    @ToolbarContentBuilder
    private func reminderToolbar(for destination: FolderDestination?) -> some ToolbarContent {
        if isSelectingReminders {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark", action: finishSelection)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
            }
            ToolbarItemGroup(placement: .topBarLeading) {
                Button("Delete Selected Reminders", systemImage: "trash") {
                    let ids = Set(selectedReminderRows.map(\.reminder))
                    if !ids.isEmpty { pendingDeletionIDs = ids }
                }
                .labelStyle(.iconOnly)
                .disabled(selectedReminderRows.isEmpty)
                Menu("Selection Options", systemImage: "ellipsis") {
                    Button("Mark as Completed", systemImage: "largecircle.fill.circle", action: completeSelectedReminders)
                        .disabled(completableSelection(at: .now).isEmpty)
                }
                .labelStyle(.iconOnly)
                .disabled(selectedReminderRows.isEmpty)
            }
        } else if destination != .completed && destination != .upcoming && destination != .deleted {
            ToolbarItem(placement: .topBarTrailing) {
                newReminderButton {
                    switch destination {
                    case .today:
                        reminderEditorRequest = ReminderEditorRequest(folder: nil, dueDate: .now)
                    case let .folder(id):
                        if let folder = folders.first(where: { $0.persistentModelID == id }) {
                            reminderEditorRequest = ReminderEditorRequest(folder: folder)
                        }
                    default:
                        reminderEditorRequest = ReminderEditorRequest(folder: nil)
                    }
                }
            }
        }
    }

    private func finishSelection() {
        withAnimation {
            selectedReminderRows.removeAll()
            reminderEditMode = .inactive
        }
    }

    private func deleteSelectedReminders(_ ids: Set<PersistentIdentifier>) {
        withAnimation {
            for reminder in reminders where !reminder.isDeleted && ids.contains(reminder.persistentModelID) {
                reminder.deletedAt = .now
            }
            if saveChanges() { finishSelection() }
        }
    }

    private func completableSelection(at date: Date) -> [Reminder] {
        let ids = Set(selectedReminderRows.map(\.reminder))
        let candidates = reminders.filter {
            ids.contains($0.persistentModelID) && !$0.isDeleted && !$0.isCompleted &&
                ($0.completionUnlockAt ?? .distantPast) <= date
        }
        guard !candidates.isEmpty else { return [] }
        let blocked = Reminder.laterOpenOccurrences(in: reminders)
        return candidates.filter { !blocked.contains($0.persistentModelID) }
    }

    private func completeSelectedReminders() {
        let date = Date.now
        let candidates = completableSelection(at: date)
        guard !candidates.isEmpty else { return }
        withAnimation(.smooth(duration: 0.3)) {
            for reminder in candidates {
                reminder.complete(in: modelContext, at: date)
            }
            if saveChanges() { finishSelection() }
        }
    }

    private func folderLink(
        _ name: Text, icon: String, count: Int, destination: FolderDestination
    ) -> some View {
        folderNavigationRow(to: destination) {
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

    private func folderNavigationRow<Label: View>(
        to destination: FolderDestination, @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            guard openedFolder == nil else { return }
            openedFolder = destination
        } label: {
            HStack(spacing: 10) {
                label()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectionDisabled()
    }

    private func todaySection(_ today: [Reminder], grouped: Bool = false) -> some View {
        Section {
            let name = String(localized: "Today")
            if grouped {
                folderHeader(name, status: today.isEmpty ? "All done" : "\(today.count) remaining", destination: .today)
            }
            let completedIDs = Set(reminders.compactMap(\.calendarOccurrenceID))
            let calendarItems = todayCalendarItems.filter { item in
                guard showsCalendarItems, !completedIDs.contains(item.id) else { return false }
                switch item.kind {
                case .birthday: return showsBirthdays
                case .allDay: return showsAllDayEvents
                case .timed: return showsTimedEvents
                }
            }
            reminderRows(today, in: .today)
            if !calendarItems.isEmpty {
                TodayCalendarRows(
                    items: calendarItems,
                    markingIDs: calendarItemsBeingCompleted,
                    isSelectingReminders: isSelectingReminders,
                    markComplete: markCalendarItemComplete
                )
            }
            if grouped {
                addReminderRow(in: name) {
                    reminderEditorRequest = ReminderEditorRequest(folder: nil, dueDate: .now)
                }
            }
        }
    }

    @ViewBuilder
    private func folderActions(for folder: ReminderFolder) -> some View {
        Button("Delete Folder", systemImage: "trash", role: .destructive) {
            withAnimation {
                modelContext.delete(folder)
                saveChanges()
            }
        }
        Button("Rename Folder", systemImage: "pencil") {
            folderToRename = folder
            folderName = folder.name
            showingNamePrompt = true
        }
    }

    @ViewBuilder
    private func folderSections(
        _ folder: ReminderFolder?, reminders: [Reminder], at date: Date, todayIDs: Set<PersistentIdentifier> = [], grouped: Bool = false
    ) -> some View {
        let name = folder?.name ?? String(localized: "Inbox")
        let remaining = reminders.filter { !$0.isCompleted }
        let nextDay = Calendar.current.dateInterval(of: .day, for: date)?.end ?? date
        let active = remaining.filter { ($0.dueDate ?? .distantPast) < nextDay }
        let upcoming = remaining.compactMap { reminder -> (reminder: Reminder, due: Date)? in
            guard let due = reminder.dueDate, due >= nextDay else { return nil }
            return (reminder, due)
        }
        .sorted { $0.due < $1.due }
        .map(\.reminder)
        let rowContext = ReminderListSection.folder(folder?.persistentModelID)
        let completedRepeats = reminders.filter { reminder in
            reminder.isCompleted && (reminder.repeatMode == ReminderRepeatMode.regularly.rawValue ||
                                     reminder.repeatMode == ReminderRepeatMode.afterCompletion.rawValue)
        }
        .sorted(by: Reminder.completedMoreRecently)

        if grouped {
            Section {
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
                reminderRows(remaining, in: rowContext, todayIDs: todayIDs)
                addReminderRow(in: name) {
                    reminderEditorRequest = ReminderEditorRequest(folder: folder)
                }
                if folder != nil && !completedRepeats.isEmpty {
                    Text("Completed Repeats")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    reminderRows(completedRepeats, in: .folderHistory)
                }
            }
        } else {
            if !active.isEmpty {
                Section("Active") {
                    reminderRows(active, in: rowContext, todayIDs: todayIDs)
                }
            }
            if !upcoming.isEmpty {
                Section("Upcoming") {
                    reminderRows(upcoming, in: rowContext)
                }
            }
            if folder != nil && !completedRepeats.isEmpty {
                Section("Completed Repeats") {
                    reminderRows(completedRepeats, in: .folderHistory)
                }
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
        folderNavigationRow(to: destination) {
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
            let isWaitingToComplete = (reminder.completionUnlockAt ?? .distantPast) > .now
            let isBlockedOccurrence = isWaitingToComplete || blockedOccurrences.contains(row.id.reminder)
            let completionSymbol = isBlockedOccurrence ? "lock.circle" : (row.isCompleted || isMarkingComplete ? "checkmark.circle.fill" : "circle")
            let repeatDescription = repeatDetails(for: reminder)
            let label = VStack(alignment: .leading, spacing: 2) {
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
                if isWaitingToComplete, let unlock = reminder.completionUnlockAt {
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

            ReminderSelectionRow(isSelecting: isSelectingReminders) { controlWidth in
                if !isSelectingReminders {
                    Button {
                        guard !isBlockedOccurrence else { return }
                        guard reminder.isCompleted else {
                            markCompleteWithFeedback(reminder)
                            return
                        }
                        withAnimation {
                            if reminder.calendarOccurrenceID != nil {
                                modelContext.delete(reminder)
                            } else {
                                do {
                                    try reminder.reopen(in: modelContext, snoozedAlarmIDs: snoozedAlarmIDs)
                                } catch {
                                    showingSaveError = true
                                    return
                                }
                            }
                            saveChanges()
                        }
                    } label: {
                        Image(systemName: completionSymbol)
                            .font(.title2)
                            .foregroundStyle(isMarkingComplete ? Color.accentColor : row.isCompleted ? .secondary : .secondary.opacity(0.5))
                            .contentTransition(.symbolEffect(.replace))
                            // Match the native edit accessory's center within the row inset.
                            .frame(width: 24)
                            .offset(y: -0.5)
                            .frame(width: controlWidth, alignment: .leading)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isBlockedOccurrence ? "Completion unavailable" : isMarkingComplete ? "Completing reminder" : row.isCompleted ? "Mark incomplete" : "Mark complete")
                    .accessibilityHint(reminder.title)
                }

            } label: {
                if reminder.calendarOccurrenceID != nil {
                    label
                } else {
                    Button {
                        guard !isSelectingReminders else { return }
                        reminderEditorRequest = ReminderEditorRequest(reminder: reminder)
                    } label: {
                        label
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(!isSelectingReminders)
                    .accessibilityRemoveTraits(isSelectingReminders ? .isButton : [])
                    .accessibilityHint(isSelectingReminders ? "" : "Edit reminder")
                }
            }
            .tag(row.id)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .swipeActions(allowsFullSwipe: false) {
                if !isSelectingReminders {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        withAnimation {
                            reminder.deletedAt = .now
                            saveChanges()
                        }
                    }
                }
            }
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
                completion.calendarOccurrenceID = item.id
                modelContext.insert(completion)
                completion.complete(in: modelContext)
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

    @discardableResult
    private func saveChanges() -> Bool {
        do {
            try modelContext.save()
            TodayWidgetUpdates.refresh(from: modelContext)
            return true
        } catch {
            modelContext.rollback()
            showingSaveError = true
            return false
        }
    }
}

private struct ReminderListBounds: ViewModifier {
    @State private var bounds = CGRect.zero

    func body(content: Content) -> some View {
        content
            .environment(\.reminderListBounds, bounds)
            .onGeometryChange(for: CGRect.self) { proxy in
                let frame = proxy.frame(in: .global)
                return CGRect(x: frame.minX, y: 0, width: frame.width, height: 0)
            } action: { bounds = $0 }
    }
}

private extension EnvironmentValues {
    @Entry var reminderListBounds = CGRect.zero
}

private struct ReminderSelectionRow<Control: View, Label: View>: View {
    let isSelecting: Bool
    @ViewBuilder let control: (CGFloat) -> Control
    @ViewBuilder let label: () -> Label
    @Environment(\.layoutDirection) private var direction
    @Environment(\.reminderListBounds) private var listBounds
    @ScaledMetric(relativeTo: .title2) private var scaledControlWidth: CGFloat = 44
    @State private var measurement: RowMeasurement?

    private struct RowMeasurement: Equatable {
        let listWidth: CGFloat
        let fullRowWidth: CGFloat
    }

    var body: some View {
        let controlWidth = max(44, scaledControlWidth)
        let labelWidth = measurement.map { max(0, $0.fullRowWidth - controlWidth) }

        label()
            .frame(width: labelWidth, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            .padding(.leading, labelWidth == nil && !isSelecting ? controlWidth : 0)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
            .overlay(alignment: labelWidth == nil ? .leading : .trailing) {
                ZStack {
                    control(controlWidth)
                }
                .frame(width: controlWidth)
                .animation(.default, value: isSelecting)
                .padding(.trailing, labelWidth ?? 0)
            }
            .transaction(value: isSelecting) { $0.animation = nil }
        .onGeometryChange(for: RowMeasurement?.self) { proxy in
            guard listBounds.width > 0 else { return nil }
            let row = proxy.frame(in: .global)
            // The list moves the leading edge for the selection circle. Mirror the trailing inset
            // to recover the full row width independently of that accessory.
            let halfWidth = direction == .leftToRight ? row.maxX - listBounds.midX : listBounds.midX - row.minX
            let accessoryInset = halfWidth * 2 - proxy.size.width
            // During a navigation push, the list and its hosted rows can report different origins.
            let maximumInset = isSelecting ? controlWidth + 1 : 1
            guard proxy.size.width > 0, (-1...maximumInset).contains(accessoryInset) else { return nil }
            let fullRowWidth = isSelecting ? halfWidth * 2 : proxy.size.width
            return RowMeasurement(listWidth: listBounds.width, fullRowWidth: fullRowWidth)
        } action: { next in
            // Keep the width through accessory transitions and horizontal swipe actions.
            if let next, next.listWidth != measurement?.listWidth {
                measurement = next
            }
        }
    }
}
