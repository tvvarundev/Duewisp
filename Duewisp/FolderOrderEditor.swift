import SwiftUI

struct FolderOrderEditor<Folder: Hashable>: View {
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [Folder]
    let name: (Folder) -> String
    let saveOrder: ([Folder]) -> Void

    init(folders: [Folder], name: @escaping (Folder) -> String, saveOrder: @escaping ([Folder]) -> Void) {
        self.name = name
        self.saveOrder = saveOrder
        _folders = State(initialValue: folders)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(folders, id: \.self) { folder in
                    Text(name(folder))
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
                    Button("Done") {
                        saveOrder(folders)
                        dismiss()
                    }
                }
            }
        }
    }
}
