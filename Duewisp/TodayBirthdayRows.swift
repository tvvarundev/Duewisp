import EventKit
import SwiftUI
import UIKit

struct TodayBirthdayRows: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var store: EKEventStore?
    @State private var access = EKEventStore.authorizationStatus(for: .event)
    @State private var birthdays: [Birthday] = []
    @State private var requestingAccess = false
    @State private var showingAccessError = false

    private struct Birthday: Identifiable {
        let id: String
        let title: String
    }

    var body: some View {
        Group {
            switch access {
            case .fullAccess:
                ForEach(birthdays) { birthday in
                    Label(birthday.title, systemImage: "birthday.cake")
                }
            case .denied:
                Button("Allow Calendar Access in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            case .restricted:
                Text("Calendar access is restricted.")
                    .foregroundStyle(.secondary)
            default:
                Button("Connect Calendar", systemImage: "calendar") {
                    Task { await connectCalendar() }
                }
                .disabled(requestingAccess)
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: RunLoop.main)) { _ in
            if scenePhase == .active { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            if scenePhase == .active { refresh() }
        }
        .alert("Couldn’t Connect Calendar", isPresented: $showingAccessError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try again.")
        }
    }

    private func eventStore() -> EKEventStore {
        if let store { return store }
        let newStore = EKEventStore()
        store = newStore
        return newStore
    }

    private func connectCalendar() async {
        guard !requestingAccess else { return }
        requestingAccess = true
        defer { requestingAccess = false }
        do {
            _ = try await eventStore().requestFullAccessToEvents()
        } catch {
            showingAccessError = true
        }
        refresh()
    }

    private func refresh() {
        access = EKEventStore.authorizationStatus(for: .event)
        guard access == .fullAccess else {
            birthdays = []
            return
        }

        let store = eventStore()
        let calendars = store.calendars(for: .event).filter { $0.type == .birthday }
        let today = calendar.startOfDay(for: .now)
        guard !calendars.isEmpty, let end = calendar.date(byAdding: .day, value: 1, to: today) else {
            birthdays = []
            return
        }

        let predicate = store.predicateForEvents(withStart: today, end: end, calendars: calendars)
        birthdays = store.events(matching: predicate).compactMap { event -> Birthday? in
            guard let date = event.startDate, date >= today, date < end,
                  let id = event.eventIdentifier, let title = event.title else { return nil }
            return Birthday(id: "\(id)-\(date.timeIntervalSinceReferenceDate)", title: title)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
