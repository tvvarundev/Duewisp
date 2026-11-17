import AlarmKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Reminder.createdAt, order: .reverse) private var reminders: [Reminder]
    @Query(sort: \ReminderFolder.name) private var folders: [ReminderFolder]
    @State private var newReminder: NewReminder?
    @State private var reminderToEdit: Reminder?
    @State private var folderToRename: ReminderFolder?
    @State private var folderName = ""
    @State private var showingNamePrompt = false
    @State private var showingSaveError = false
    @State private var showingFolderOrder = false
    @State private var snoozedAlarmIDs: Set<UUID> = []

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

    var body: some View {
        let alerts = scenePhase == .active ? notificationAlerts : nil
        NavigationStack {
            let now = Date.now
            let calendar = Calendar.current
            let upcoming = reminders.filter { !$0.isCompleted }.flatMap { reminder in
                [reminder.availableAt, reminder.dueDate.map { calendar.startOfDay(for: $0) }]
                    .compactMap { $0 }
                    .filter { $0 > now }
            }
            TimelineView(.explicit([now] + Set(upcoming).sorted())) { _ in
                reminderList(at: .now)
            }
            .navigationTitle("Reminders")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Folder Options", systemImage: "ellipsis.circle") {
                        Button("Reorder Folders", systemImage: "arrow.up.arrow.down") {
                            showingFolderOrder = true
                        }
                    }
                    .disabled(folders.count < 2)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        folderToRename = nil
                        folderName = ""
                        showingNamePrompt = true
                    }
                    .labelStyle(.iconOnly)

                    Spacer()

                    Button("New Reminder", systemImage: "plus") {
                        newReminder = NewReminder(folder: nil)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
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

    @available(iOS 26.0, *)
    private func updateSnoozedAlarms(_ alarms: [Alarm]) {
        // Duewisp alarms use countdowns only after snoozing.
        snoozedAlarmIDs = Set(alarms.filter { $0.state == .countdown }.map(\.id))
    }

    private func reminderList(at date: Date) -> some View {
        let visible = reminders.filter { $0.isCompleted || ($0.availableAt ?? .distantPast) <= date }
        let calendar = Calendar.current
        let today = visible.filter { reminder in
            guard !reminder.isCompleted, let dueDate = reminder.dueDate else { return false }
            return calendar.compare(dueDate, to: date, toGranularity: .day) != .orderedDescending
        }
        let completed = visible.filter(\.isCompleted)
        let todayIDs = Set(today.map(\.persistentModelID))
        let remindersByFolder = Dictionary(grouping: visible) {
            $0.folder?.persistentModelID
        }
        let inbox = (remindersByFolder[nil] ?? []).filter { !todayIDs.contains($0.persistentModelID) }

        return List {
            folderSection(nil, reminders: inbox)

            Section {
                folderHeader(String(localized: "Today"), status: today.isEmpty ? "All done" : "\(today.count) remaining")
                reminderRows(today, in: .today)
                TodayBirthdayRows()
                addReminderRow(in: String(localized: "Today")) {
                    newReminder = NewReminder(folder: nil, dueDate: .now)
                }
            }

            ForEach(orderedFolders) { folder in
                folderSection(folder, reminders: remindersByFolder[folder.persistentModelID] ?? [], todayIDs: todayIDs)
            }

            if !completed.isEmpty {
                Section {
                    folderHeader(String(localized: "Completed"), status: "\(completed.count) completed")
                    reminderRows(completed, in: .completed)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 0, for: .scrollContent)
    }

    private func folderSection(
        _ folder: ReminderFolder?, reminders: [Reminder], todayIDs: Set<PersistentIdentifier> = []
    ) -> some View {
        let name = folder?.name ?? String(localized: "Inbox")
        let remaining = reminders.filter { !$0.isCompleted }
        let completedRepeats = reminders.filter { reminder in
            reminder.isCompleted && (reminder.repeatMode == ReminderRepeatMode.regularly.rawValue ||
                                     reminder.repeatMode == ReminderRepeatMode.afterCompletion.rawValue)
        }
        let status: LocalizedStringKey
        if reminders.isEmpty {
            status = "No reminders"
        } else if remaining.isEmpty {
            status = "All done"
        } else {
            status = "\(remaining.count) remaining"
        }

        return Section {
            folderHeader(name, status: status)
            .swipeActions(allowsFullSwipe: false) {
                if let folder {
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
            }

            reminderRows(remaining, in: .folder(folder?.persistentModelID), todayIDs: todayIDs)

            addReminderRow(in: name) {
                newReminder = NewReminder(folder: folder)
            }

            if folder != nil && !completedRepeats.isEmpty {
                Text("Completed Repeats")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                reminderRows(completedRepeats, in: .folderHistory)
            }
        }
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

    private func folderHeader(_ name: String, status: LocalizedStringKey) -> some View {
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

    private enum ReminderListSection: Hashable {
        case today, completed, folderHistory
        case folder(PersistentIdentifier?)
    }

    private struct ReminderRowID: Hashable {
        let reminder: PersistentIdentifier
        let section: ReminderListSection
    }

    private func reminderRows(
        _ reminders: [Reminder], in section: ReminderListSection, todayIDs: Set<PersistentIdentifier> = []
    ) -> some View {
        let today = Calendar.current.startOfDay(for: .now)
        let rows = reminders.map { reminder in
            let badge: Text?
            if section == .today, let folder = reminder.folder {
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
            let repeatDescription = repeatDetails(for: reminder)
            HStack(spacing: 0) {
                Button {
                    withAnimation {
                        if reminder.isCompleted {
                            reminder.isCompleted = false
                        } else {
                            reminder.complete(in: modelContext)
                        }
                        saveChanges()
                    }
                } label: {
                    Image(systemName: row.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(row.isCompleted ? Color.secondary : Color.secondary.opacity(0.5))
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(row.isCompleted ? "Mark incomplete" : "Mark complete")
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
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Edit reminder")

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
