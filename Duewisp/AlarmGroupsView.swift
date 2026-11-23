import SwiftData
import SwiftUI
import UIKit

private func repeatSummary(_ days: [Int], calendar: Calendar = .current) -> String {
    if days.isEmpty { return String(localized: "Never") }
    if days.count == 7 { return String(localized: "Every Day") }
    let ordered = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    return ordered.filter(days.contains).map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
}

struct AlarmGroupsView: View {
    let groups: [AlarmGroup]
    let scheduledIDs: Set<UUID>?
    let isPermissionDenied: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @State private var showingNewGroup = false
    @State private var groupToEdit: AlarmGroup?
    @State private var groupToDelete: AlarmGroup?
    @State private var showingDelete = false
    @State private var showingSaveError = false

    var body: some View {
        NavigationStack {
            Group {
                if #available(iOS 26.0, *) {
                    TimelineView(.everyMinute) { context in
                        groupList(at: context.date)
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("New Alarm Group", systemImage: "plus") { showingNewGroup = true }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Grouped Alarms Require iOS 26",
                        systemImage: "alarm",
                        description: Text("Update iOS to schedule alarm groups.")
                    )
                }
            }
            .navigationTitle("Alarms")
            .sheet(isPresented: $showingNewGroup) {
                AlarmGroupEditor(group: nil)
            }
            .sheet(item: $groupToEdit) { group in
                AlarmGroupEditor(group: group)
            }
            .alert("Delete Alarm Group?", isPresented: $showingDelete, presenting: groupToDelete) { group in
                Button("Delete", role: .destructive) {
                    modelContext.delete(group)
                    save()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn’t Save Alarm Group", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func groupList(at date: Date) -> some View {
        List {
            if isPermissionDenied {
                Section {
                    Button("Allow Alarms in Settings", systemImage: "gear") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } footer: {
                    Text("Duewisp needs alarm access before enabled groups can ring.")
                }
            }
            ForEach(groups) { group in
                let days = group.repeatDays ?? []
                let enabledTimes = group.alarms.filter(\.isEnabled)
                let future = enabledTimes.compactMap { alarm -> (id: UUID, date: Date)? in
                    if days.isEmpty { return alarm.date > date ? (alarm.id, alarm.date) : nil }
                    let calendar = Calendar.current
                    let clock = calendar.dateComponents([.hour, .minute], from: alarm.date)
                    let next = days.compactMap { weekday in
                        calendar.nextDate(after: date, matching: DateComponents(hour: clock.hour, minute: clock.minute, second: 0, weekday: weekday), matchingPolicy: .nextTime)
                    }.min()
                    return next.map { (alarm.id, $0) }
                }.sorted { $0.date < $1.date }
                HStack {
                    Button {
                        groupToEdit = group
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name)
                                .foregroundStyle(.primary)
                            timePreview(enabledTimes.map(\.date))
                            let detail = days.isEmpty
                                ? (group.dateEnabled == false ? String(localized: "Once") : group.alarms.first?.date.formatted(date: .abbreviated, time: .omitted) ?? "")
                                : repeatSummary(days)
                            if let scheduledIDs, group.alarms.contains(where: {
                                (!group.isEnabled || !$0.isEnabled) && scheduledIDs.contains($0.id)
                            }) {
                                Text("Alarms are still scheduled")
                                    .foregroundStyle(.orange)
                                    .font(.subheadline)
                            } else if let next = future.first, group.isEnabled {
                                if let scheduledIDs, future.contains(where: { !scheduledIDs.contains($0.id) }) {
                                    Text("Some alarms aren’t scheduled")
                                        .foregroundStyle(.orange)
                                        .font(.subheadline)
                                } else {
                                    Text("\(detail) · Next: \(next.date.formatted(date: days.isEmpty && group.dateEnabled != false ? .omitted : .abbreviated, time: .shortened))")
                                        .foregroundStyle(.secondary)
                                        .font(.subheadline)
                                }
                            } else {
                                Text(future.isEmpty && !enabledTimes.isEmpty ? "\(detail) · No upcoming alarms" : "\(detail)")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    Toggle("Enable \(group.name)", isOn: Binding(
                        get: { group.isEnabled },
                        set: {
                            group.isEnabled = $0
                            save()
                        }
                    ))
                    .labelsHidden()
                }
                .swipeActions(allowsFullSwipe: false) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        groupToDelete = group
                        showingDelete = true
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if groups.isEmpty && !isPermissionDenied {
                ContentUnavailableView(
                    "No Alarm Groups",
                    systemImage: "alarm",
                    description: Text("Tap + to set several alarms for the same date.")
                )
            }
        }
    }

    @ViewBuilder
    private func timePreview(_ dates: [Date]) -> some View {
        let calendar = Calendar.current
        let sorted = dates.sorted {
            calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0)
                < calendar.component(.hour, from: $1) * 60 + calendar.component(.minute, from: $1)
        }
        let full = sorted.map { $0.formatted(date: .omitted, time: .shortened) }
        if sorted.isEmpty {
            Text("No enabled times").font(.subheadline).foregroundStyle(.secondary)
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach((1...sorted.count).reversed(), id: \.self) { count in
                    let times = (0..<count).map { index in
                        if index + 1 < count,
                           calendar.component(.hour, from: sorted[index]) / 12 == calendar.component(.hour, from: sorted[index + 1]) / 12 {
                            return sorted[index].formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                        }
                        return full[index]
                    }.joined(separator: " · ")
                    if count == sorted.count {
                        Text(times)
                    } else {
                        Text("\(times) · +\(sorted.count - count) more")
                    }
                }
                Text("\(sorted.count) enabled")
            }
            .lineLimit(1)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text(full.joined(separator: ", ")))
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            showingSaveError = true
        }
    }
}

private struct AlarmGroupEditor: View {
    let group: AlarmGroup?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.calendar) private var calendar
    @State private var name: String
    @State private var hasDate: Bool
    @State private var dateExpanded = false
    @State private var weekdays: [Int]
    @State private var day: Date
    @State private var times: [Time]
    @State private var expandedTimeID: UUID?
    @State private var showingSaveError = false
    @FocusState private var nameFocused: Bool

    private struct Time: Identifiable {
        let id = UUID()
        var value: Date
        var isEnabled = true
    }

    init(group: AlarmGroup?) {
        self.group = group
        let existing = (group?.alarms ?? []).sorted { $0.date < $1.date }
        let first = existing.first?.date ?? .now.addingTimeInterval(300)
        _name = State(initialValue: group?.name ?? "")
        _hasDate = State(initialValue: group.map { $0.dateEnabled ?? true } ?? false)
        _weekdays = State(initialValue: group?.repeatDays ?? [])
        _day = State(initialValue: first)
        _times = State(initialValue: existing.isEmpty ? [Time(value: first)] : existing.map {
            Time(value: $0.date, isEnabled: $0.isEnabled)
        })
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var alarmTimes: [(date: Date, isEnabled: Bool)] {
        times.compactMap { time in
            let components = calendar.dateComponents([.hour, .minute], from: time.value)
            if !hasDate && weekdays.isEmpty {
                if let saved = group?.alarms.first(where: { $0.date == time.value }), group?.dateEnabled == false,
                   (group?.repeatDays ?? []).isEmpty { return (saved.date, time.isEnabled) }
                var clock = components
                clock.second = 0
                return calendar.nextDate(after: .now, matching: clock, matchingPolicy: .nextTime).map { ($0, time.isEnabled) }
            }
            if !weekdays.isEmpty { return (time.value, time.isEnabled) }
            guard let hour = components.hour, let minute = components.minute,
                  let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day, matchingPolicy: .strict),
                  calendar.isDate(date, inSameDayAs: day) else { return nil }
            return (date, time.isEnabled)
        }
    }

    var body: some View {
        let dates = alarmTimes.map(\.date)
        let clockTimes = dates.map { calendar.dateComponents([.hour, .minute], from: $0) }
        let hasDuplicateTimes = Set(clockTimes).count != dates.count
        NavigationStack {
            Form {
                Section {
                    TextField("Group Name", text: $name)
                        .focused($nameFocused)
                    TogglePickerRow(title: "Date", systemImage: "calendar", isOn: Binding(
                        get: { hasDate },
                        set: { enabled in
                            hasDate = enabled
                            dateExpanded = enabled
                            if enabled {
                                weekdays = []
                                day = max(day, calendar.startOfDay(for: .now))
                                expandedTimeID = nil
                            }
                            nameFocused = false
                        }
                    ), value: day.formatted(date: .abbreviated, time: .omitted), isExpanded: dateExpanded) {
                        nameFocused = false
                        expandedTimeID = nil
                        dateExpanded.toggle()
                    }
                    if hasDate && dateExpanded {
                        DatePicker("Date", selection: $day, in: min(calendar.startOfDay(for: .now), day)..., displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                    }
                    NavigationLink {
                        List {
                            ForEach(0..<7, id: \.self) { offset in
                                let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
                                let selected = weekdays.contains(weekday)
                                Button {
                                    if selected { weekdays.removeAll { $0 == weekday } }
                                    else {
                                        weekdays.append(weekday)
                                        weekdays.sort()
                                        hasDate = false
                                        dateExpanded = false
                                    }
                                } label: {
                                    HStack {
                                        Text("Every \(calendar.weekdaySymbols[weekday - 1])").foregroundStyle(.primary)
                                        Spacer()
                                        if selected { Image(systemName: "checkmark") }
                                    }
                                }
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                        .navigationTitle("Repeat")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        LabeledContent("Repeat", value: repeatSummary(weekdays, calendar: calendar))
                    }
                }
                Section {
                    ForEach($times) { $time in
                        let id = time.id
                        let isExpanded = expandedTimeID == id
                        TogglePickerRow(
                            title: "Time",
                            systemImage: "clock",
                            isOn: timeToggle($time),
                            value: time.value.formatted(date: .omitted, time: .shortened),
                            isExpanded: isExpanded,
                            onPress: { nameFocused = false }
                        ) {
                            dateExpanded = false
                            expandedTimeID = isExpanded ? nil : id
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Remove Alarm", systemImage: "trash", role: .destructive) {
                                if isExpanded { expandedTimeID = nil }
                                times.removeAll { $0.id == id }
                            }
                        }

                        if time.isEnabled && isExpanded {
                            DatePicker("Alarm Time", selection: $time.value, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.wheel)
                                .labelsHidden()
                        }
                    }

                    Button("Add Alarm", systemImage: "plus") {
                        nameFocused = false
                        let last = times.last?.value ?? .now
                        let time = Time(value: last.addingTimeInterval(300))
                        dateExpanded = false
                        times.append(time)
                        expandedTimeID = time.id
                    }
                } header: {
                    Text("Alarm Times")
                } footer: {
                    if dates.count != times.count {
                        Text("Choose times that exist on this date.")
                    } else if hasDuplicateTimes {
                        Text("Choose a different time for each alarm.")
                    } else if weekdays.isEmpty && alarmTimes.contains(where: { $0.isEnabled && $0.date <= .now }) {
                        Text("Only future times will ring.")
                    }
                }
            }
            .navigationTitle(group == nil ? "New Alarm Group" : "Edit Alarm Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", action: save)
                        .labelStyle(.iconOnly)
                        .disabled(trimmedName.isEmpty || times.isEmpty || dates.count != times.count || hasDuplicateTimes)
                }
            }
            .alert("Couldn’t Save Alarm Group", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func timeToggle(_ time: Binding<Time>) -> Binding<Bool> {
        Binding(
            get: { time.wrappedValue.isEnabled },
            set: { enabled in
                nameFocused = false
                time.wrappedValue.isEnabled = enabled
                let id = time.wrappedValue.id
                if enabled {
                    dateExpanded = false
                    expandedTimeID = id
                } else if expandedTimeID == id {
                    expandedTimeID = nil
                }
            }
        )
    }

    private func save() {
        let groupToSave = group ?? AlarmGroup(name: trimmedName)
        if group == nil { modelContext.insert(groupToSave) }
        groupToSave.update(name: trimmedName, times: alarmTimes, weekdays: weekdays, dateEnabled: hasDate, in: modelContext)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            showingSaveError = true
        }
    }
}
