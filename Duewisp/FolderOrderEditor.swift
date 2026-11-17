import SwiftData
import SwiftUI

struct FolderOrderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var folders: [ReminderFolder]
    @State private var showingSaveError = false

    init(folders: [ReminderFolder]) {
        _folders = State(initialValue: folders)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(folders) { folder in
                    Text(folder.name)
                }
                .onMove { offsets, destination in
                    folders.move(fromOffsets: offsets, toOffset: destination)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save)
                }
            }
            .alert("Couldn’t Save Folder Order", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func save() {
        for (index, folder) in folders.enumerated() {
            folder.sortOrder = index
        }
        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            showingSaveError = true
        }
    }
}
