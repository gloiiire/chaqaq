import SwiftUI

// ── Root view: 3-tab layout ──────────────────────────────────────────────────

/// Root view — four tabs: Notes, Databases, Inbox, Search. The create
/// bubble lives in the TabView's bottom accessory so it docks alongside
/// the auto-positioned search bubble at the same vertical level as the
/// tab bar (iOS 26 multi-bubble layout, à la Photos / Music).
struct ContentView: View {
    @StateObject private var store = PinkhaStore()
    @StateObject private var composer = Composer()
    @StateObject private var tabManager = TabManager()
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        rootTabs
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
        .environmentObject(tabManager)
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
                onImportCraftCombined: { composer.showingCraftCombinedImport = true },
                onShowAllDocs: { composer.showingAllDocs = true }
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
        .fullScreenCover(isPresented: $composer.showingAllDocs) {
            AllDocumentsSwitcher(store: store) { docId in
                composer.showingAllDocs = false
                composer.pendingOpenDoc = docId
            }
            .environmentObject(settings)
            .environmentObject(tabManager)
            // The switcher's `+` bottom-bar action needs `composer`
            // to trigger the create-doc sheet. `fullScreenCover`
            // doesn't always propagate env objects to its content
            // root in iOS 26 — explicit injection is required.
            .environmentObject(composer)
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
        .modifier(ContentAlerts(composer: composer, store: store))
        .onAppear { store.connect() }
        .task { composer.bindQuickActions() }
        .errorAlert(message: $store.errorMessage, onRetry: store.load)
    }

    /// Bundles the three top-level alerts (new folder, delete-all
    /// step 1, delete-all step 2) into a single modifier so the
    /// SwiftUI type-checker can chew through `body` — inlining the
    /// alerts on top of every `.sheet` / `.fullScreenCover` already
    /// stacked there blew the "unable to type-check in reasonable
    /// time" budget.
    private struct ContentAlerts: ViewModifier {
        @ObservedObject var composer: Composer
        @ObservedObject var store: PinkhaStore

        func body(content: Content) -> some View {
            content
                .alert("New Folder", isPresented: $composer.showingNewFolder) {
                    TextField("Name", text: $composer.newFolderName)
                    Button("Create") {
                        let trimmed = composer.newFolderName
                            .trimmingCharacters(in: .whitespaces)
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
        }
    }

    /// The 4-tab root. Extracted so the SwiftUI type-checker doesn't
    /// blow up on `body` once every `.sheet` / `.alert` modifier piles
    /// up — we hit the "unable to type-check this expression in
    /// reasonable time" wall when both were inlined.
    @ViewBuilder
    private var rootTabs: some View {
        TabView {
            Tab("Notes", systemImage: "note.text") {
                NotesHomeView(store: store)
            }
            Tab("Databases", systemImage: "tablecells") {
                DatabasesHomeView(store: store)
            }
            Tab("Inbox",
                systemImage: store.hasInboxNotification ? "tray.badge.fill" : "tray.fill") {
                InboxView(store: store)
            }
            Tab(role: .search) {
                SearchView(store: store)
            }
        }
    }
}

// ── Preview ───────────────────────────────────────────────────────────────────

#if DEBUG
/// Single root preview that mirrors `PinkhaApp.body` — wraps the
/// whole app so the Xcode Canvas can iterate on it without a full
/// build/install round-trip. Note that the iOS 26 `TabView` chrome
/// (tab bar + bottom accessory) and any layout that depends on it
/// still need a simulator/device to render properly; the Canvas is
/// best for in-view edits (typography, spacing inside content, etc.).
#Preview {
    ContentView()
        .environmentObject(AppSettings())
        .tint(AppSettings().accentColor)
}
#endif

// ── Tab 2: Search ─────────────────────────────────────────────────────────────

/// Search tab — full-workspace super search. Hits four axes in parallel
/// (note titles, note content, database titles, folder names) and groups
/// the matches in sections. Each section is hidden when empty.
private struct SearchView: View {
    @ObservedObject var store: PinkhaStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var tabManager: TabManager
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
                                    destination: DocumentView(vm: tabManager.open(docId: doc.id, api: api),
                                                              onDisappear: store.load)
                                ) { WorkspaceRow(item: .note(doc)) }
                            }
                        } header: { SectionHeader(title: "Notes") }
                    }
                    if !results.documentsByContent.isEmpty {
                        ForEach(groupHits(results.documentsByContent),
                                id: \.doc.id) { group in
                            Section {
                                ForEach(group.hits, id: \.blockId) { hit in
                                    NavigationLink(
                                        destination: DocumentView(
                                            vm: tabManager.open(docId: hit.doc.id, api: api),
                                            onDisappear: store.load,
                                            scrollToBlockId: hit.blockId
                                        )
                                    ) {
                                        SnippetRow(hit: hit, query: query)
                                    }
                                }
                            } header: {
                                DocHitSectionHeader(doc: group.doc)
                            }
                        }
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
            // `.searchable` is backed by `UISearchTextField` which
            // ignores SwiftUI's `.tint` env. We push the colour
            // through the UIKit appearance proxy — applies to search
            // bars instantiated after this point, which covers the
            // re-mount that happens when the toggle flips.
            .onAppear { applySearchBarTint() }
            .onChange(of: settings.cursorFollowsAccent) { _, _ in
                applySearchBarTint()
            }
            .onChange(of: settings.accentChoice) { _, _ in
                applySearchBarTint()
            }
        }
    }

    @MainActor
    private func applySearchBarTint() {
        let color: UIColor = settings.cursorFollowsAccent
            ? UIColor(settings.accentColor)
            : .white
        UISearchTextField.appearance().tintColor = color
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

// ── Doc-hit section header ────────────────────────────────────────────────────

/// Non-interactive header for the per-doc grouping of block hits.
/// Surfaces the doc icon and title above its snippet rows; doesn't
/// own a NavigationLink because the snippets themselves are the
/// navigation targets.
private struct DocHitSectionHeader: View {
    let doc: DocumentMetaFfi

    var body: some View {
        HStack(spacing: 10) {
            if let icon = doc.icon, !icon.isEmpty {
                Text(icon).font(.body)
            } else {
                Image(systemName: "doc.text")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Group {
                if doc.titlePlain.isEmpty { Text("Untitled") } else { Text(doc.titlePlain) }
            }
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

// ── Snippet row ───────────────────────────────────────────────────────────────

/// Single snippet row — owns exactly one NavigationLink (set by the
/// caller) so iOS's back-stack stays unambiguous. The matched tokens
/// in `hit.snippet` are bolded à la Notion.
private struct SnippetRow: View {
    let hit: BlockSearchHitFfi
    let query: String

    var body: some View {
        Text(highlightedSnippet)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }

    private var highlightedSnippet: AttributedString {
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
