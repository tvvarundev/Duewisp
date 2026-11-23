import SwiftData
import SwiftUI

struct ReminderEditor: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReminderFolder.name) private var folders: [ReminderFolder]
    @State private var selectedFolder: ReminderFolder?
    @State private var title: String
    @State private var hasDueDate: Bool
    @State private var hasDueTime: Bool
    @State private var expandedPicker: DuePicker?
    @State private var dueDate: Date
    @State private var usesAlarm: Bool
    @State private var snoozeMinutes: Int
    @State private var repeats: Bool
    @State private var repeatMode: ReminderRepeatMode
    @State private var repeatUnit: ReminderRepeatUnit
    @State private var repeatInterval: Int
    @State private var hasRepeatStartDate: Bool
    @State private var repeatStartDate: Date
    @State private var hasRepeatEndDate: Bool
    @State private var repeatEndDate: Date
    @State private var showingSaveError = false
    @FocusState private var titleFocused: Bool
    private let reminder: Reminder?

    private enum DuePicker {
        case date, time, alarm, repeatInterval, startDate, endDate
    }

    init(reminder: Reminder? = nil, initialFolder: ReminderFolder? = nil, initialDueDate: Date? = nil) {
        self.reminder = reminder
        _selectedFolder = State(initialValue: reminder?.folder ?? initialFolder)
        _title = State(initialValue: reminder?.title ?? "")
        let selectedDueDate = reminder?.dueDate ?? initialDueDate
        _hasDueDate = State(initialValue: selectedDueDate != nil)
        _hasDueTime = State(initialValue: reminder?.dueDate != nil && reminder?.isDateOnly != true)
        _dueDate = State(initialValue: selectedDueDate ?? .now)
        _usesAlarm = State(initialValue: reminder?.alarmID != nil)
        _snoozeMinutes = State(initialValue: reminder?.snoozeMinutes ?? Reminder.defaultSnoozeMinutes)
        let savedMode = ReminderRepeatMode(rawValue: reminder?.repeatMode ?? "") ?? .never
        _repeats = State(initialValue: savedMode != .never)
        _repeatMode = State(initialValue: savedMode == .afterCompletion ? .afterCompletion : .regularly)
        _repeatUnit = State(initialValue: ReminderRepeatUnit(rawValue: reminder?.repeatUnit ?? "") ?? .days)
        _repeatInterval = State(initialValue: reminder?.repeatInterval ?? 1)
        let today = Calendar.current.startOfDay(for: .now)
        _hasRepeatStartDate = State(initialValue: savedMode != .regularly || reminder?.repeatStartDate != nil)
        _repeatStartDate = State(initialValue: reminder?.repeatStartDate ?? today)
        _hasRepeatEndDate = State(initialValue: reminder?.repeatEndDate != nil)
        _repeatEndDate = State(initialValue: reminder?.repeatEndDate ?? max(selectedDueDate ?? today, today))
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var usesRegularSchedule: Bool {
        repeats && repeatMode == .regularly
    }

    private var dateToggle: Binding<Bool> {
        Binding(get: { hasDueDate }, set: { enabled in
            titleFocused = false
            hasDueDate = enabled
            expandedPicker = enabled ? .date : nil
            if !enabled {
                hasDueTime = false
                usesAlarm = false
            }
        })
    }

    private var timeToggle: Binding<Bool> {
        Binding(get: { hasDueTime }, set: { enabled in
            titleFocused = false
            hasDueTime = enabled
            expandedPicker = enabled ? .time : nil
            if enabled {
                if !repeats { enableDateIfNeeded() }
            } else {
                usesAlarm = false
            }
        })
    }

    private var alarmToggle: Binding<Bool> {
        Binding(get: { usesAlarm }, set: { enabled in
            titleFocused = false
            usesAlarm = enabled
            expandedPicker = enabled ? .alarm : nil
            guard enabled else { return }
            if !repeats { enableDateIfNeeded() }
            if !hasDueTime {
                dueDate = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: dueDate) ?? dueDate
                hasDueTime = true
            }
        })
    }

    private var selectedDueDate: Date? {
        if usesRegularSchedule {
            if reminder?.generatedOccurrenceID != nil, let currentDate = reminder?.dueDate {
                return dateWithSelectedTime(on: max(calendar.startOfDay(for: currentDate), calendar.startOfDay(for: regularRepeatAnchor)))
            }
            return regularRepeatAnchor
        }
        if repeats {
            if let currentDate = reminder?.dueDate, reminder?.repeatMode == ReminderRepeatMode.afterCompletion.rawValue {
                return dateWithSelectedTime(on: currentDate)
            }
            return hasDueTime ? dateWithSelectedTime(on: .now) : nil
        }
        guard hasDueDate else { return nil }
        return hasDueTime ? dueDate : calendar.startOfDay(for: dueDate)
    }

    private var regularRepeatAnchor: Date {
        dateWithSelectedTime(on: hasRepeatStartDate ? repeatStartDate : .now)
    }

    private func dateWithSelectedTime(on date: Date) -> Date {
        let day = calendar.startOfDay(for: date)
        guard hasDueTime else { return day }
        let time = calendar.dateComponents([.hour, .minute], from: dueDate)
        return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }

    private var invalidRepeatDates: Bool {
        usesRegularSchedule && hasRepeatEndDate &&
            calendar.compare(repeatEndDate, to: regularRepeatAnchor, toGranularity: .day) == .orderedAscending
    }

    var body: some View {
        let today = calendar.startOfDay(for: .now)
        NavigationStack {
            ScrollViewReader { scroll in
                Form {
                    Section {
                        TextField("Title", text: $title, axis: .vertical)
                            .focused($titleFocused)
                        if !folders.isEmpty {
                            Picker("Folder", selection: $selectedFolder) {
                                Text("Inbox").tag(nil as ReminderFolder?)
                                ForEach(folders) { folder in
                                    Text(folder.name).tag(folder as ReminderFolder?)
                                }
                            }
                        }
                    } header: {
                        Text("Details")
                    } footer: {
                        Text("Give your reminder a title and choose where to keep it.")
                    }

                    if !repeats {
                        Section {
                            duePickerRow(
                                "Date", systemImage: "calendar", isOn: dateToggle,
                                value: dateSummary(dueDate),
                                picker: .date
                            )
                            if hasDueDate && expandedPicker == .date {
                                inlineDatePicker("Due Date", selection: $dueDate, from: today)
                            }
                            timeAndAlarmRows
                        } header: {
                            if #available(iOS 26.0, *) {
                                Text("Date and Alarm")
                            } else {
                                Text("Date")
                            }
                        } footer: {
                            if #available(iOS 26.0, *) {
                                Text("Choose a date and add a time for an alert. Turn on Alarm to have your iPhone ring at that time.")
                            } else {
                                Text("Set when the reminder is due.")
                            }
                        }
                    }

                    Section {
                        Toggle("Repeat", isOn: $repeats)
                        if repeats {
                            Picker("Repeat Mode", selection: $repeatMode) {
                                Text(ReminderRepeatMode.regularly.rawValue).tag(ReminderRepeatMode.regularly)
                                Text(ReminderRepeatMode.afterCompletion.rawValue).tag(ReminderRepeatMode.afterCompletion)
                            }
                            repeatIntervalRow
                                .id(DuePicker.repeatInterval)
                            if usesRegularSchedule {
                                duePickerRow(
                                    "Start Date", systemImage: "calendar", isOn: startDateToggle,
                                    value: dateSummary(repeatStartDate), picker: .startDate
                                )
                                if hasRepeatStartDate && expandedPicker == .startDate {
                                    inlineDatePicker("Start Date", selection: $repeatStartDate, from: today)
                                }
                            }
                            timeAndAlarmRows
                            if usesRegularSchedule {
                                let earliestEnd = max(today, calendar.startOfDay(for: regularRepeatAnchor))
                                duePickerRow(
                                    "End Date", systemImage: "calendar", isOn: endDateToggle,
                                    value: dateSummary(repeatEndDate), picker: .endDate
                                )
                                if hasRepeatEndDate && expandedPicker == .endDate {
                                    inlineDatePicker("End Date", selection: $repeatEndDate, from: earliestEnd)
                                }
                                if invalidRepeatDates {
                                    Text("End date must be on or after the start date.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Repeat")
                    } footer: {
                        Text("Regular repeats start from the selected date and default to today. Repeats after completion count from when you finish.")
                    }
                }
                .onChange(of: expandedPicker) {
                    guard expandedPicker == .repeatInterval else { return }
                    withAnimation(reduceMotion ? nil : .smooth(duration: PickerRowPressStyle.releaseDuration)) {
                        scroll.scrollTo(DuePicker.repeatInterval, anchor: .bottom)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: selectedFolder) { titleFocused = false }
            .onChange(of: dueDate) { titleFocused = false }
            .onChange(of: snoozeMinutes) { titleFocused = false }
            .onChange(of: repeats) {
                titleFocused = false
                if repeats && (expandedPicker == .date || expandedPicker == .time || expandedPicker == .alarm) {
                    expandedPicker = nil
                }
            }
            .onChange(of: repeatMode) { titleFocused = false }
            .onChange(of: usesRegularSchedule) { _, isRegular in
                if isRegular {
                    hasRepeatStartDate = true
                } else if expandedPicker == .startDate || expandedPicker == .endDate {
                    expandedPicker = nil
                }
            }
            .onChange(of: hasRepeatEndDate) { titleFocused = false }
            .onChange(of: repeatEndDate) { titleFocused = false }
            .navigationTitle(reminder == nil ? "New Reminder" : "Edit Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        dismiss()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", action: save)
                        .labelStyle(.iconOnly)
                        .disabled(trimmedTitle.isEmpty || invalidRepeatDates)
                }
            }
            .alert("Couldn’t Save Reminder", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please try again.")
            }
        }
    }

    private var repeatIntervalRow: some View {
        let isExpanded = expandedPicker == .repeatInterval
        return VStack(spacing: 0) {
            repeatDisclosureRow(
                "Every", value: "\(repeatInterval.formatted()) \(repeatUnit.intervalLabel(for: repeatInterval))",
                picker: .repeatInterval
            )

            HStack(spacing: 0) {
                Picker("Repeat interval", selection: $repeatInterval) {
                    ForEach(1...99, id: \.self) { value in
                        Text(value, format: .number).tag(value)
                    }
                }
                .frame(maxWidth: .infinity)
                .clipped()

                Picker("Repeat unit", selection: $repeatUnit) {
                    ForEach(ReminderRepeatUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(height: 216)
            .frame(height: isExpanded ? 216 : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
        }
    }

    private func repeatDisclosureRow(_ title: LocalizedStringKey, value: String, picker: DuePicker) -> some View {
        let isExpanded = expandedPicker == picker
        return Button {
            titleFocused = false
            withAnimation(reduceMotion ? nil : .smooth(duration: PickerRowPressStyle.releaseDuration)) {
                expandedPicker = isExpanded ? nil : picker
            }
        } label: {
            LabeledContent {
                Text(value)
                    .foregroundStyle(Color.accentColor)
            } label: {
                Text(title).foregroundStyle(.primary)
            }
            .transaction { $0.animation = nil }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(value)
        .accessibilityHint(isExpanded ? "Collapses picker" : "Expands picker")
    }

    private func enableDateIfNeeded() {
        guard !hasDueDate else { return }
        dueDate = .now
        hasDueDate = true
    }

    private func duePickerRow(
        _ title: LocalizedStringKey, systemImage: String, isOn: Binding<Bool>, value: String, picker: DuePicker
    ) -> some View {
        let isExpanded = expandedPicker == picker
        return TogglePickerRow(
            title: title, systemImage: systemImage, isOn: isOn, value: value, isExpanded: isExpanded,
            onPress: { titleFocused = false }
        ) {
            expandedPicker = isExpanded ? nil : picker
        }
    }

    @ViewBuilder
    private var timeAndAlarmRows: some View {
        duePickerRow(
            "Time", systemImage: "clock", isOn: timeToggle,
            value: dueDate.formatted(date: .omitted, time: .shortened), picker: .time
        )
        if hasDueTime && expandedPicker == .time {
            DatePicker("Time", selection: $dueDate, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
        }
        if #available(iOS 26.0, *) {
            duePickerRow(
                "Alarm", systemImage: "alarm", isOn: alarmToggle,
                value: snoozeMinutes == Reminder.snoozeOff
                    ? String(localized: "Snooze · Off")
                    : String(localized: "Snooze · \(snoozeMinutes) min"),
                picker: .alarm
            )
            if usesAlarm && expandedPicker == .alarm {
                Picker("Snooze Duration", selection: $snoozeMinutes) {
                    Text("Off").tag(Reminder.snoozeOff)
                    ForEach([5, 10, 15, 20, 25, 30, 45, 60], id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
            }
        }
    }

    private var startDateToggle: Binding<Bool> {
        Binding(get: { hasRepeatStartDate }, set: { enabled in
            titleFocused = false
            hasRepeatStartDate = enabled
            expandedPicker = enabled ? .startDate : nil
        })
    }

    private var endDateToggle: Binding<Bool> {
        Binding(get: { hasRepeatEndDate }, set: { enabled in
            titleFocused = false
            hasRepeatEndDate = enabled
            expandedPicker = enabled ? .endDate : nil
            if enabled {
                let earliestEnd = calendar.startOfDay(for: max(.now, regularRepeatAnchor))
                repeatEndDate = max(repeatEndDate, earliestEnd)
            }
        })
    }

    private func dateSummary(_ date: Date) -> String {
        calendar.isDateInToday(date) ? String(localized: "Today") : date.formatted(date: .abbreviated, time: .omitted)
    }

    @ViewBuilder
    private func inlineDatePicker(_ title: LocalizedStringKey, selection: Binding<Date>, from earliest: Date) -> some View {
        if selection.wrappedValue < earliest {
            LabeledContent {
                Button("Choose New Date") {
                    selection.wrappedValue = earliest
                }
            } label: {
                Text(title)
            }
        } else {
            let picker = DatePicker(title, selection: selection, in: earliest..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            if #available(iOS 26.0, *) {
                picker.listRowInsets(.top, 0)
            } else {
                picker.listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
            }
        }
    }

    private func save() {
        guard !invalidRepeatDates else { return }
        let item = reminder ?? Reminder(title: trimmedTitle, dueDate: selectedDueDate)
        let originalAlarmID = item.alarmID
        let originalSnoozeMinutes = item.alarmSnoozeMinutes
        if selectedDueDate == nil || !hasDueTime || !usesAlarm {
            item.alarmStopped = nil
            item.alarmID = nil
        } else if item.alarmID == nil || item.dueDate != selectedDueDate || item.title != trimmedTitle {
            item.alarmStopped = nil
            item.alarmID = UUID()
        }
        item.alarmSnoozeMinutes = item.alarmID != nil ? snoozeMinutes : nil
        let mode = repeats ? repeatMode.rawValue : nil
        let unit = repeats ? repeatUnit.rawValue : nil
        let interval = repeats ? repeatInterval : nil
        let dateOnly = (selectedDueDate != nil || repeats) && !hasDueTime ? true : nil
        let startDate = usesRegularSchedule && hasRepeatStartDate ? calendar.startOfDay(for: repeatStartDate) : nil
        let endDate = usesRegularSchedule && hasRepeatEndDate ? calendar.startOfDay(for: repeatEndDate) : nil
        let repeatConfigurationChanged = reminder == nil || item.dueDate != selectedDueDate ||
            item.repeatMode != mode || item.repeatUnit != unit || item.repeatInterval != interval ||
            item.repeatStartDate != startDate
        let occurrenceChanged = repeatConfigurationChanged || item.title != trimmedTitle ||
            item.isDateOnly != dateOnly || item.folder?.persistentModelID != selectedFolder?.persistentModelID ||
            item.repeatEndDate != endDate || item.alarmID != originalAlarmID ||
            item.alarmSnoozeMinutes != originalSnoozeMinutes
        if item.generatedOccurrenceID != nil && occurrenceChanged {
            item.generatedOccurrenceWasEdited = true
        }
        if repeatConfigurationChanged {
            item.earlyCompletionUnlockAt = nil
            if usesRegularSchedule {
                item.repeatAnchor = regularRepeatAnchor
                item.repeatStartDate = startDate
            } else {
                item.repeatAnchor = repeats ? (selectedDueDate ?? .now) : nil
                item.repeatStartDate = nil
            }
        }
        item.title = trimmedTitle
        if let availableAt = item.availableAt, availableAt > .now, let selectedDueDate {
            item.availableAt = selectedDueDate
        }
        item.dueDate = selectedDueDate
        item.isDateOnly = dateOnly
        item.folder = selectedFolder
        item.repeatMode = mode
        item.repeatUnit = unit
        item.repeatInterval = interval
        item.repeatEndDate = endDate
        if reminder == nil { modelContext.insert(item) }

        do {
            try modelContext.save()
            TodayWidgetUpdates.refresh(from: modelContext)
            dismiss()
        } catch {
            modelContext.rollback()
            showingSaveError = true
        }
    }
}
