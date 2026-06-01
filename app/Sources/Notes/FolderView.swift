import SwiftUI

// ── Folder content view ───────────────────────────────────────────────────────

/// Shows all documents inside a single folder. Tapping a row opens the document.
struct FolderView: View {
    @ObservedObject var store: PinkhaStore
    let folder: FolderMetaFfi

    var body: some View {
        let docs = store.documentsInFolder(folderId: folder.id)
        List {
            if docs.isEmpty {
                Text("No notes in this folder yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if let api = store.api {
                ForEach(docs, id: \.id) { doc in
                    NavigationLink(destination: DocumentView(docId: doc.id, api: api,
                                                              onDisappear: store.load)) {
                        WorkspaceRow(item: .note(doc))
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet { store.delete(id: docs[i].id) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.large)
    }
}

// ── Folders section ───────────────────────────────────────────────────────────

/// Section that lists top-level folders in `NotesHomeView`.
struct FoldersSectionView: View {
    @ObservedObject var store: PinkhaStore
    @State private var showingNewFolder = false
    @State private var newFolderName = ""

    var body: some View {
        let folders = store.listFolders().filter { $0.parentId == nil }
        Section {
            ForEach(folders, id: \.id) { folder in
                NavigationLink(destination: FolderView(store: store, folder: folder)) {
                    Label(folder.name, systemImage: "folder")
                }
            }
            .onDelete { indexSet in
                for i in indexSet { store.deleteFolder(id: folders[i].id) }
            }

            Button {
                showingNewFolder = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
                    .foregroundStyle(.tint)
            }
        } header: {
            SectionHeader(title: "Folders")
        }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                guard !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                store.createFolder(name: newFolderName)
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
    }
}
