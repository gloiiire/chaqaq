import SwiftUI

// ── Root view: 3-tab layout ──────────────────────────────────────────────────

/// Root view — four tabs: Notes, Databases, Inbox, Search. The create
/// bubble lives in the TabView's bottom accessory so it docks alongside
/// the auto-positioned search bubble at the same vertical level as the
/// tab bar (iOS 26 multi-bubble layout, à la Photos / Music).
struct ContentView: View {
    @StateObject private var store = PinkhaStore()
    @StateObject private var composer = Composer()

    var body: some View {
        TabView {
            Tab("Notes", systemImage: "note.text") {
                NotesHomeView(store: store)
            }
            Tab("Databases", systemImage: "tablecells") {
                DatabasesHomeView(store: store)
            }
            // Inbox : the SF Symbol swaps from `tray.fill` to `tray.badge.fill`
            // when `hasInboxNotification` flips on, giving a clear "you have
            // something to look at" cue without relying on .badge() (which
            // we reserve for actual unread counts).
            Tab("Inbox",
                systemImage: store.hasInboxNotification ? "tray.badge.fill" : "tray.fill") {
                InboxView(store: store)
            }
            Tab(role: .search) {
                SearchView(store: store)
            }
        }
        // iOS 26 tab-bar morphing : the tab bar collapses when the user
        // scrolls down so the content gets more breathing room, and
        // reappears on scroll-up. Search (role: .search) automatically
        // detaches into its own glass bubble on the right.
        .tabBarMinimizeBehavior(.onScrollDown)
        // Create bubble : single glass accessory hosting the four primary
        // entry points — new note, new database, new folder and an
        // overflow menu (trash + imports). Stays visible across all tabs
        // so creation is always one tap away, à la Apple Music mini-player.
        .tabViewBottomAccessory {
            CreateBubble(
                onNewNote: { composer.openNewNote() },
                onNewDatabase: { composer.openNewDatabase() },
                onNewFolder: { composer.openNewFolder() },
                onShowTrash: { composer.showingTrash = true },
                onDeleteAll: { composer.showingDeleteAllConfirm = true },
                hasItemsForDeleteAll: !store.items.isEmpty,
                onImportNotion: { composer.showingNotionImport = true },
                onImportBear: { composer.showingBearImport = true },
                onImportCraftTextBundle: { composer.showingCraftTextBundleImport = true },
                onImportCraftCombined: { composer.showingCraftCombinedImport = true }
            )
        }
        .sheet(isPresented: $composer.showingCreateDoc) {
            CreateDocumentSheet(
                title: $composer.newTitle,
                prompt: composer.createMode == .note ? "Note title" : "Database title"
            ) {
                switch composer.createMode {
                case .note:     store.create(title: composer.newTitle)
                case .database: store.createDatabase(title: composer.newTitle)
                }
                composer.newTitle = ""
                composer.showingCreateDoc = false
            } onCancel: {
                composer.newTitle = ""
                composer.showingCreateDoc = false
            }
        }
        .sheet(isPresented: $composer.showingTrash) {
            TrashView().environmentObject(store)
        }
        .sheet(isPresented: $composer.showingNotionImport) {
            NotionImportView(api: store.api) { store.load() }
        }
        .sheet(isPresented: $composer.showingBearImport) {
            BearImportView(api: store.api) { store.load() }
        }
        .sheet(isPresented: $composer.showingCraftTextBundleImport) {
            CraftTextBundleImportView(api: store.api) { store.load() }
        }
        .sheet(isPresented: $composer.showingCraftCombinedImport) {
            CraftCombinedImportView(api: store.api) { store.load() }
        }
        .alert("New folder", isPresented: $composer.showingNewFolder) {
            TextField("Name", text: $composer.newFolderName)
            Button("Create") {
                let trimmed = composer.newFolderName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                store.createFolder(name: trimmed)
                store.load()
                composer.newFolderName = ""
            }
            Button("Cancel", role: .cancel) { composer.newFolderName = "" }
        }
        .alert("Delete all \(store.items.count) notes?",
               isPresented: $composer.showingDeleteAllConfirm) {
            Button("Delete All", role: .destructive) {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    composer.showingDeleteAllConfirm2 = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all your notes.")
        }
        .alert("Are you sure?", isPresented: $composer.showingDeleteAllConfirm2) {
            Button("Yes, delete everything", role: .destructive) {
                store.deleteAll()
                store.deleteAllDatabases()
                store.deleteAllFolders()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .onAppear { store.connect() }
        .errorAlert(message: $store.errorMessage, onRetry: store.load)
    }
}

// ── Tab 2: Search ─────────────────────────────────────────────────────────────

/// Search tab — owns its own .searchable so it does not bleed into other tabs.
private struct SearchView: View {
    @ObservedObject var store: PinkhaStore
    @State private var query = ""

    private var results: [DocumentMetaFfi] {
        query.isEmpty ? [] : store.search(query: query)
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Label("Type to search", systemImage: "text.magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.top, 32)
                } else if results.isEmpty {
                    Text("No results for \"\(query)\"")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.top, 32)
                } else {
                    if let api = store.api {
                        ForEach(results, id: \.id) { doc in
                            NavigationLink(
                                destination: DocumentView(docId: doc.id, api: api,
                                                          onDisappear: store.load)
                            ) {
                                WorkspaceRow(item: .note(doc))
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Note titles…")
            .autocorrectionDisabled()
        }
    }
}
