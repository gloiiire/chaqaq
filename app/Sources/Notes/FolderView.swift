import SwiftUI

// ── Folder content view ───────────────────────────────────────────────────────

/// Shows the contents of a single folder: its sub-folders (Craft-style nesting)
/// then its documents. Tapping a sub-folder pushes another `FolderView` onto
/// the same NavigationStack, giving arbitrary-depth navigation for free.
struct FolderView: View {
    @ObservedObject var store: PinkhaStore
    let folder: FolderMetaFfi

    @State private var showingNewSubFolder = false
    @State private var newSubFolderName = ""

    var body: some View {
        let subFolders = store.childFolders(of: folder.id)
        let docs = store.documentsInFolder(folderId: folder.id)

        List {
            // ── Sub-folders ───────────────────────────────────────────────
            // Always present so the user can create the first sub-folder
            // even when the folder only contains docs (or is empty).
            Section {
                ForEach(subFolders, id: \.id) { sub in
                    NavigationLink(destination: FolderView(store: store, folder: sub)) {
                        Label(sub.name, systemImage: "folder")
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet { store.deleteFolder(id: subFolders[i].id) }
                }

                Button {
                    newSubFolderName = ""
                    showingNewSubFolder = true
                } label: {
                    Label("New sub-folder", systemImage: "folder.badge.plus")
                        .foregroundStyle(.tint)
                }
            } header: {
                SectionHeader(title: "Folders")
            }

            // ── Documents ─────────────────────────────────────────────────
            Section {
                if docs.isEmpty {
                    Text("No notes in this folder yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
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
            } header: {
                SectionHeader(title: "Notes")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.large)
        .alert("New sub-folder", isPresented: $showingNewSubFolder) {
            TextField("Name", text: $newSubFolderName)
            Button("Create") {
                let trimmed = newSubFolderName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                store.createFolder(name: trimmed, parentId: folder.id)
                store.load()
                newSubFolderName = ""
            }
            Button("Cancel", role: .cancel) { newSubFolderName = "" }
        }
    }
}

// ── Folders section ───────────────────────────────────────────────────────────

/// Section that lists top-level folders in `NotesHomeView`.
struct FoldersSectionView: View {
    @ObservedObject var store: PinkhaStore
    @State private var showingNewFolder = false
    @State private var newFolderName = ""

    var body: some View {
        let folders = store.childFolders(of: nil)
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
