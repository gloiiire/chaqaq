import SwiftUI

// ── Root view: 3-tab layout ──────────────────────────────────────────────────

/// Root view — four tabs: Notes, Databases, Inbox, Search. The create
/// bubble lives in the TabView's bottom accessory so it docks alongside
/// the auto-positioned search bubble at the same vertical level as the
/// tab bar (iOS 26 multi-bubble layout, à la Photos / Music).
struct ContentView: View {
    @StateObject private var store = PinkhaStore()
    @StateObject private var composer = Composer()
    @EnvironmentObject private var settings: AppSettings

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
        // Tint applied right on the TabView (BEFORE the .alert/.sheet
        // modifiers below) so only the selected-tab indicator picks up
        // the accent. Placing it later in the chain would have caused
        // the alerts/sheets attached afterwards to inherit the orange
        // env and repaint their default Buttons.
        .tint(settings.accentColor)
        // Inject the Composer so deep navigation destinations
        // (FolderView, DocumentView) can flip the creation context
        // when they appear / disappear without having to be passed
        // through every NavigationLink call site.
        .environmentObject(composer)
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
                prompt: composer.createMode == .note ? "Note title" : "Database title",
                navigationTitle: composer.createMode == .note ? "New Document" : "New Database"
            ) {
                switch composer.createMode {
                case .note:
                    let newId = store.createNote(title: composer.newTitle,
                                                 in: composer.currentContext)
                    if case .document(let parentId) = composer.currentContext,
                       let newId {
                        // For `.document` context, the active editor's
                        // VM owns the in-memory blocks. Signal it via
                        // the composer so *it* performs the `addBlock`
                        // for the Page reference — doing it from here
                        // behind the VM's back would race with the
                        // next burst flush and get overwritten.
                        composer.pendingChildPage = Composer.PendingChildPage(
                            parentDocId: parentId,
                            childDocId: newId
                        )
                    } else if let newId {
                        // Root or folder context — open the doc right
                        // after the sheet dismisses so the user lands
                        // in the editor (Apple Notes / Bear pattern).
                        composer.pendingOpenDoc = newId
                    }
                case .database:
                    store.createDatabase(title: composer.newTitle, in: composer.currentContext)
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
        // Belt-and-braces refresh : the import sheets each call store.load()
        // when the user taps Done, but they can also be dismissed by a
        // swipe-down or Cancel — paths where the existing completion
        // callback doesn't fire. We listen on each `isPresented` falling
        // edge to guarantee the home picks up whatever the importer
        // committed to SQLite before the dismiss.
        .onChange(of: composer.showingNotionImport) { _, isShowing in
            if !isShowing { store.load() }
        }
        .onChange(of: composer.showingBearImport) { _, isShowing in
            if !isShowing { store.load() }
        }
        .onChange(of: composer.showingCraftTextBundleImport) { _, isShowing in
            if !isShowing { store.load() }
        }
        .onChange(of: composer.showingCraftCombinedImport) { _, isShowing in
            if !isShowing { store.load() }
        }
        .alert("New folder", isPresented: $composer.showingNewFolder) {
            TextField("Name", text: $composer.newFolderName)
            Button("Create") {
                let trimmed = composer.newFolderName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                store.createFolder(name: trimmed, in: composer.currentContext)
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

/// Search tab — full-workspace super search. Hits four axes in parallel
/// (note titles, note content, database titles, folder names) and groups
/// the matches in sections. Each section is hidden when empty.
private struct SearchView: View {
    @ObservedObject var store: PinkhaStore
    @State private var query = ""

    private var results: PinkhaStore.SuperSearchResults {
        query.isEmpty ? .empty : store.superSearch(query: query)
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
                } else if let api = store.api {
                    if !results.documentsByTitle.isEmpty {
                        Section {
                            ForEach(results.documentsByTitle, id: \.id) { doc in
                                NavigationLink(
                                    destination: DocumentView(docId: doc.id, api: api,
                                                              onDisappear: store.load)
                                ) { WorkspaceRow(item: .note(doc)) }
                            }
                        } header: { SectionHeader(title: "Notes") }
                    }
                    if !results.documentsByContent.isEmpty {
                        Section {
                            // Group block hits by document so a single
                            // doc never duplicates as a row — instead it
                            // shows the doc header once and one snippet
                            // line per matching block underneath,
                            // separated by dividers à la home view.
                            ForEach(groupHits(results.documentsByContent),
                                    id: \.doc.id) { group in
                                GroupedBlockHitRow(group: group,
                                                   query: query,
                                                   api: api,
                                                   onDocClose: store.load)
                            }
                        } header: { SectionHeader(title: "In notes") }
                    }
                    if !results.databases.isEmpty {
                        Section {
                            ForEach(results.databases, id: \.id) { db in
                                NavigationLink(
                                    destination: DatabaseView(dbId: db.id, api: api,
                                                              onDisappear: store.load)
                                ) { WorkspaceRow(item: .database(db)) }
                            }
                        } header: { SectionHeader(title: "Databases") }
                    }
                    if !results.folders.isEmpty {
                        Section {
                            ForEach(results.folders, id: \.id) { folder in
                                NavigationLink(
                                    destination: FolderView(store: store, folder: folder)
                                ) { FolderRow(folder: folder) }
                            }
                        } header: { SectionHeader(title: "Folders") }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search notes, content, databases, folders…")
            .autocorrectionDisabled()
        }
    }
}

// ── Search hit grouping ───────────────────────────────────────────────────────

/// One document plus every block-level hit that matched in it. Lets the
/// search UI show a single header per doc with multiple snippet previews
/// nested underneath instead of duplicating the doc row N times.
private struct DocHitGroup {
    let doc: DocumentMetaFfi
    let hits: [BlockSearchHitFfi]
}

/// Preserves first-seen order while grouping hits by `doc.id`. The Rust
/// backend returns hits document-by-document, depth-first within each
/// doc — keeping that order means the topmost match in the doc is the
/// first snippet shown.
private func groupHits(_ hits: [BlockSearchHitFfi]) -> [DocHitGroup] {
    var order: [String] = []
    var bucket: [String: [BlockSearchHitFfi]] = [:]
    var docs: [String: DocumentMetaFfi] = [:]
    for hit in hits {
        if bucket[hit.doc.id] == nil {
            order.append(hit.doc.id)
            docs[hit.doc.id] = hit.doc
        }
        bucket[hit.doc.id, default: []].append(hit)
    }
    return order.compactMap { id in
        guard let doc = docs[id], let arr = bucket[id] else { return nil }
        return DocHitGroup(doc: doc, hits: arr)
    }
}

// ── Grouped block-content hit row ─────────────────────────────────────────────

/// Row for a "matched in note content" search result. Renders the doc
/// icon + title once on top, then one snippet preview per matching
/// block underneath — each preview is its own NavigationLink so tapping
/// it jumps straight to the corresponding block in the document.
/// Dividers between previews mirror the home-view list look.
private struct GroupedBlockHitRow: View {
    let group: DocHitGroup
    let query: String
    let api: PinkhaApi
    let onDocClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Doc header — tapping it opens the doc at the first hit.
            NavigationLink(
                destination: DocumentView(docId: group.doc.id,
                                          api: api,
                                          onDisappear: onDocClose,
                                          scrollToBlockId: group.hits.first?.blockId)
            ) {
                HStack(spacing: 12) {
                    if let icon = group.doc.icon, !icon.isEmpty {
                        Text(icon).font(.title2).frame(width: 34, height: 34)
                    } else {
                        Image(systemName: "doc.text")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(.secondary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    Text(group.doc.titlePlain.isEmpty ? "Untitled" : group.doc.titlePlain)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            // Snippet previews — each one navigates to its own block.
            ForEach(Array(group.hits.enumerated()), id: \.element.blockId) { index, hit in
                if index > 0 {
                    Divider().padding(.leading, 46)
                }
                NavigationLink(
                    destination: DocumentView(docId: hit.doc.id,
                                              api: api,
                                              onDisappear: onDocClose,
                                              scrollToBlockId: hit.blockId)
                ) {
                    HStack(alignment: .top, spacing: 12) {
                        // Aligned with the doc-header icon column so
                        // snippets read like indented continuation lines.
                        Color.clear.frame(width: 34, height: 1)
                        Text(highlightedSnippet(for: hit))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
            }
        }
    }

    /// Builds an AttributedString from `hit.snippet` with every
    /// case-insensitive occurrence of each query token rendered bold.
    /// Empty tokens (extra spaces) are skipped so a trailing space in
    /// the search bar doesn't bold the entire snippet.
    private func highlightedSnippet(for hit: BlockSearchHitFfi) -> AttributedString {
        var attr = AttributedString(hit.snippet)
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        for token in tokens {
            highlight(token, in: &attr)
        }
        return attr
    }

    private func highlight(_ token: String, in attr: inout AttributedString) {
        var cursor = attr.startIndex
        let needle = token.lowercased()
        while cursor < attr.endIndex,
              let range = attr[cursor...].range(of: needle,
                                                options: .caseInsensitive) {
            attr[range].font = .subheadline.bold()
            attr[range].foregroundColor = .primary
            cursor = range.upperBound
        }
    }
}
