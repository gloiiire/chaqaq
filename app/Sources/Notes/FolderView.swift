import SwiftUI

// ── Folder content view ───────────────────────────────────────────────────────

/// Shows the contents of a single folder: its sub-folders (Craft-style nesting)
/// then its documents. Tapping a sub-folder pushes another `FolderView` onto
/// the same NavigationStack, giving arbitrary-depth navigation for free.
struct FolderView: View {
    @ObservedObject var store: PinkhaStore
    let folder: FolderMetaFfi
    /// Optional Composer — injected by `ContentView`. We read it to flip
    /// `currentContext` to this folder on appear and back to `.root` on
    /// disappear, so the create bubble's "New …" land inside the folder
    /// the user is looking at.
    @EnvironmentObject private var composer: Composer
    @EnvironmentObject private var tabManager: TabManager

    @State private var showingNewSubFolder = false
    @State private var newSubFolderName = ""
    @State private var showingRename = false
    @State private var renameDraft = ""
    @State private var showingEmojiPicker = false
    @State private var recentEmojis: [String] = loadRecentEmojis()

    /// Most up-to-date copy of `folder` so a rename / icon update reflects
    /// without popping back to the parent view. Re-derived from the store
    /// on each render — `store.listFolders()` is cheap (in-memory cache).
    private var current: FolderMetaFfi {
        store.listFolders().first(where: { $0.id == folder.id }) ?? folder
    }

    var body: some View {
        let subFolders = store.childFolders(of: folder.id)
        let docs = store.documentsInFolder(folderId: folder.id)

        List {
            // ── Sub-folders ───────────────────────────────────────────────
            Section {
                ForEach(subFolders, id: \.id) { sub in
                    NavigationLink(destination: FolderView(store: store, folder: sub)) {
                        FolderRow(folder: sub)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.deleteFolder(id: sub.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
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
                        NavigationLink(destination: DocumentView(vm: tabManager.open(docId: doc.id, api: api),
                                                                  onDisappear: store.load)) {
                            WorkspaceRow(item: .note(doc))
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.delete(id: doc.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
            } header: {
                SectionHeader(title: "Notes")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Overflow menu : rename, set/clear icon. The icon picker
            // re-uses the same EmojiPickerSheet as documents so the
            // experience stays consistent across the workspace.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingEmojiPicker = true
                    } label: {
                        Label(current.icon == nil ? "Set icon" : "Change icon",
                              systemImage: "face.smiling")
                    }
                    if current.icon != nil {
                        Button(role: .destructive) {
                            store.updateFolderIcon(id: folder.id, icon: nil)
                        } label: {
                            Label("Remove icon", systemImage: "trash")
                        }
                    }
                    Divider()
                    Button {
                        renameDraft = current.name
                        showingRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More actions")
            }
        }
        .onAppear { composer.currentContext = .folder(id: folder.id) }
        .onDisappear { composer.currentContext = .root }
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
        .alert("Rename folder", isPresented: $showingRename) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                store.renameFolder(id: folder.id, newName: trimmed)
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingEmojiPicker) {
            EmojiPickerSheet(selection: current.icon, recents: recentEmojis) { emoji in
                store.updateFolderIcon(id: folder.id, icon: emoji)
                recentEmojis = saveRecentEmoji(emoji)
                showingEmojiPicker = false
            }
        }
    }

    /// Prepends the emoji to the navigation title when set, so the user
    /// sees their chosen icon at the top of the folder view too.
    private var displayTitle: String {
        if let icon = current.icon, !icon.isEmpty {
            return "\(icon)  \(current.name)"
        }
        return current.name
    }
}

// ── Folder row ────────────────────────────────────────────────────────────────

/// Row used by both `FolderView` (sub-folders) and `FoldersSectionView`
/// (root-level folders) — shows the emoji icon when set, falling back to
/// the system folder symbol otherwise.
struct FolderRow: View {
    let folder: FolderMetaFfi

    var body: some View {
        HStack(spacing: 12) {
            if let icon = folder.icon, !icon.isEmpty {
                Text(icon).font(.title3).frame(width: 28)
            } else {
                Image(systemName: "folder").foregroundStyle(.tint).frame(width: 28)
            }
            Text(folder.name)
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
                    FolderRow(folder: folder)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.deleteFolder(id: folder.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                }
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
