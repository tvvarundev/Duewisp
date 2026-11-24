import EventKit
import SwiftUI
import UIKit

struct CalendarSettings: View {
    @Binding var isEnabled: Bool
    @Binding var showsBirthdays: Bool
    @Binding var showsAllDayEvents: Bool
    @Binding var showsTimedEvents: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var access = EKEventStore.authorizationStatus(for: .event)
    @State private var requestingAccess = false
    @State private var showingAccessError = false

    private var calendarToggle: Binding<Bool> {
        Binding(get: { isEnabled }, set: { enabled in
            if enabled && access == .notDetermined {
                Task { await requestCalendarAccess() }
            } else {
                isEnabled = enabled
            }
        })
    }

    var body: some View {
        Section {
            Toggle("Calendar", systemImage: "calendar", isOn: calendarToggle)
                .disabled(requestingAccess)

            if isEnabled {
                switch access {
                case .denied, .writeOnly:
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                case .restricted:
                    Text("Calendar access is restricted on this device.")
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
        } footer: {
            Text("Show calendar events and birthdays in Today. Allow Full Access in iOS Settings if prompted.")
        }
        .task(id: scenePhase) {
            if scenePhase == .active {
                access = EKEventStore.authorizationStatus(for: .event)
            }
        }
        .alert("Couldn’t Connect Calendar", isPresented: $showingAccessError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try again.")
        }

        if isEnabled {
            Section("Show in Today") {
                Toggle("Birthdays", isOn: $showsBirthdays)
                Toggle("All-Day Events", isOn: $showsAllDayEvents)
                Toggle("Timed Events", isOn: $showsTimedEvents)
            }
        }
    }

    private func requestCalendarAccess() async {
        guard !requestingAccess else { return }
        requestingAccess = true
        defer {
            access = EKEventStore.authorizationStatus(for: .event)
            requestingAccess = false
        }
        do {
            let store = EKEventStore()
            _ = try await store.requestFullAccessToEvents()
            isEnabled = true
        } catch {
            isEnabled = false
            showingAccessError = true
        }
    }
}

struct TodayCalendarRows: View {
    let items: [CalendarItem]
    let markingIDs: Set<String>
    let isSelectingReminders: Bool
    let markComplete: (CalendarItem) -> Void

    struct CalendarItem: Identifiable {
        enum Kind {
            case birthday, allDay, timed
        }

        let id: String
        let title: String
        let date: Date
        let kind: Kind
    }

    var body: some View {
        ForEach(items) { item in
            let isMarking = markingIDs.contains(item.id)
            HStack(spacing: 0) {
                Button {
                    markComplete(item)
                } label: {
                    Image(systemName: isMarking ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isMarking ? Color.accentColor : Color.secondary.opacity(0.5))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isMarking ? "Completing calendar item" : "Mark complete")
                .accessibilityHint(item.title)
                .opacity(isSelectingReminders ? 0 : 1)
                .allowsHitTesting(!isSelectingReminders)
                .accessibilityHidden(isSelectingReminders)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    Text("From Calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .selectionDisabled()
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
    }

    static func load(from store: EKEventStore, calendar: Calendar) -> [CalendarItem] {
        let today = calendar.startOfDay(for: .now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }
        let predicate = store.predicateForEvents(withStart: today, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event -> CalendarItem? in
            guard let date = event.startDate, date < end, date >= today || event.endDate > today,
                  let id = event.eventIdentifier, let title = event.title else { return nil }
            return CalendarItem(
                id: "\(id)-\(date.timeIntervalSinceReferenceDate)",
                title: title,
                date: date,
                kind: event.calendar.type == .birthday ? .birthday : (event.isAllDay ? .allDay : .timed)
            )
        }
        .sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}
