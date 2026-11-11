import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("No Reminders", systemImage: "checklist")
                .navigationTitle("Reminders")
        }
    }
}
