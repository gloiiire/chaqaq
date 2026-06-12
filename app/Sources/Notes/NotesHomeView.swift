import SwiftUI

// ── Tab 1: Notes (unified workspace) ──────────────────────────────────────────

/// Home screen for the Notes tab — shows notes and databases in a unified list.
/// All creation / import / trash actions live in the global CreateBubble
/// hosted by `ContentView.tabViewBottomAccessory`, so this view focuses on
/// presenting the workspace content. Sibling files in this folder own the
/// recent strip (`RecentStrip.swift`) and the list row (`WorkspaceRow.swift`).
struct NotesHomeView: View {
    @ObservedObject var store: PinkhaStore
    @EnvironmentObject var composer: Composer
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var tabManager: TabManager
    @State private var showingSettings = false
    /// Programmatic navigation stack so a freshly-created note can be
    /// pushed onto the editor right after the create sheet dismisses
    /// — driven by `composer.pendingOpenDoc`.
    /// Programmatic navigation stack. Must stay `@State` — using a
    /// `@Published`-backed binding (e.g. moved to `Composer`) hits a
    /// SwiftUI bug where `NavigationStack(path: $model.path)` does
    /// not visibly pop when `path.removeAll()` is called from outside.
    /// External mutations route through `Composer.popHomeNotification`.
    @State private var path: [String] = []
    /// Shared geometry namespace for the Apple Music / Books-style
    /// zoom transition when a doc card opens. Source views (list
    /// rows, Recent cards) tag themselves with
    /// `.matchedTransitionSource(id:in:)`; the destination DocumentView
    /// pairs it with `.navigationTransition(.zoom(sourceID:in:))`.
    @Namespace private var docZoom
    /// Multi-select state for bulk delete. `editMode` flips between
    /// `.inactive` and `.active` via the toolbar Select button; the
    /// List binds `selection:` to `selectedIds` so the standard iOS
    /// circle UI appears next to each row when active.
    @State private var editMode: EditMode = .inactive
    @State private var selectedIds: Set<String> = []
    @State private var showingBulkDeleteConfirm = false
    /// Doc currently being renamed via the contextMenu — drives the
    /// rename alert and `renameDraft` TextField below.
    @State private var renamingDoc: DocumentMetaFfi?
    @State private var renameDraft: String = ""
    /// Doc currently picked through a "Add to a database" context
    /// menu item — drives the sheet below. `nil` = no sheet shown.
    @State var attachDocId: String?

    /// Single-property Identifiable wrapper so the doc id can drive a
    /// `.sheet(item:)` without surfacing a separate `Bool` toggle.
    struct AttachDocIdentifier: Identifiable, Equatable {
        let id: String
    }

    /// Sort + group preferences. `@AppStorage` persists them across
    /// launches without an explicit migration — each user setting maps
    /// to one `UserDefaults` key. Defaults mirror the previous implicit
    /// behaviour (most-recently-updated first, no grouping).
    @AppStorage("notes.sortKey")   var sortKeyRaw: String = SortKey.updatedAt.rawValue
    @AppStorage("notes.sortAsc")   var sortAscending: Bool = false
    @AppStorage("notes.groupBy")   var groupByRaw: String = GroupBy.none.rawValue
    /// When on, databases are hidden from the unified workspace list.
    /// The dedicated "Bases" tab still surfaces them — this flag only
    /// scopes the Notes home view's mixed feed. Off by default.
    @AppStorage("notes.hideDatabases") var hideDatabases: Bool = false

    var sortKey: SortKey {
        SortKey(rawValue: sortKeyRaw) ?? .updatedAt
    }
    var groupBy: GroupBy {
        GroupBy(rawValue: groupByRaw) ?? .none
    }

    enum SortKey: String, CaseIterable, Identifiable {
        case lastOpened, name, createdAt, updatedAt, publishedAt
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .lastOpened:  "Last opened"
            case .name:        "Name"
            case .createdAt:   "Created"
            case .updatedAt:   "Updated"
            case .publishedAt: "Published"
            }
        }
        var systemImage: String {
            switch self {
            case .lastOpened:  "clock"
            case .name:        "textformat"
            case .createdAt:   "calendar.badge.plus"
            case .updatedAt:   "calendar"
            case .publishedAt: "paperplane"
            }
        }
    }

    enum GroupBy: String, CaseIterable, Identifiable {
        case none, lastOpened, name, createdAt, updatedAt, publishedAt
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .none:        "None"
            case .lastOpened:  "Last opened"
            case .name:        "Name"
            case .createdAt:   "Created"
            case .updatedAt:   "Updated"
            case .publishedAt: "Published"
            }
        }
        var systemImage: String {
            switch self {
            case .none:        "minus.rectangle"
            case .lastOpened:  "clock"
            case .name:        "textformat"
            case .createdAt:   "calendar.badge.plus"
            case .updatedAt:   "calendar"
            case .publishedAt: "paperplane"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            // Conditional selection binding — we only let the List
            // track selection while edit mode is active. Outside of
            // it, `selectedIds` is forced to empty (writes are
            // dropped), which prevents the iOS 26 default behaviour
            // of leaving a NavigationLink-pushed row visually "focused"
            // after the user pops back.
            List(selection: Binding(
                get: { editMode == .active ? selectedIds : [] },
                set: { newValue in
                    if editMode == .active { selectedIds = newValue }
                }
            )) {
                if !recentlyViewedItems.isEmpty {
                    Section {
                        RecentStrip(
                            items: recentlyViewedItems,
                            api: store.api,
                            zoomNamespace: docZoom,
                            onDisappear: { store.load() },
                            onOpenNote: { docId in
                                path.append(docId)
                            },
                            onRenameNote: { doc in
                                renameDraft = doc.titlePlain
                                renamingDoc = doc
                            },
                            onDeleteNote: { doc in
                                store.delete(id: doc.id)
                            },
                            onAddToDatabase: store.databases.isEmpty ? nil : { doc in
                                attachDocId = doc.id
                            }
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                    } header: {
                        SectionHeader(title: "Recent")
                    }
                }

                if !store.listFolders().isEmpty {
                    FoldersSectionView(store: store)
                }

                if store.items.isEmpty {
                    Section {
                        NotesEmptyState()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } else {
                    if let api = store.api {
                        ForEach(groupedItems) { group in
                            groupSection(group, api: api)
                        }
                    } else {
                        Section { ProgressView() }
                    }
                }
            }
            .listStyle(.insetGrouped)
            // Re-tint the List with the accent so the edit-mode
            // selection circles stay readable. Without this they'd
            // inherit the `.tint(.primary)` set just before the
            // rename alert later in the chain and render white.
            .tint(settings.accentColor)
            .environment(\.editMode, $editMode)
            .navigationTitle(greeting)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.items.isEmpty {
                        Button(editMode == .active ? "Done" : "Select") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if editMode == .active {
                                    editMode = .inactive
                                    selectedIds.removeAll()
                                } else {
                                    editMode = .active
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if editMode != .active && !store.items.isEmpty {
                        sortMenuButton
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if editMode == .active {
                        // In edit mode the trailing slot becomes the
                        // primary bulk-delete action. Bottom-bar
                        // placement collides with the TabView's search
                        // bubble, so we surface the action up here.
                        Button(role: .destructive) {
                            showingBulkDeleteConfirm = true
                        } label: {
                            Label(
                                selectedIds.isEmpty ? "Delete" : "Delete (\(selectedIds.count))",
                                systemImage: "trash"
                            )
                        }
                        .tint(.red)
                        .disabled(selectedIds.isEmpty)
                    } else {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        // Settings is neutral chrome — never adopts the
                        // accent that the TabView spreads through its env.
                        .tint(.primary)
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            // Surfaced from the "Add to a database" long-press menu
            // on note rows / recents — files the existing doc as a
            // row of the picked database with the title pre-seeded.
            .sheet(item: Binding(
                get: { attachDocId.map(AttachDocIdentifier.init) },
                set: { attachDocId = $0?.id }
            )) { wrapper in
                AttachDocToDatabaseSheet(docId: wrapper.id)
                    .environmentObject(store)
                    .presentationDetents([.large])
            }
            // Native confirmation dialog before the bulk delete fires —
            // matches the Apple Notes / Mail pattern (slide-up sheet
            // anchored to the row that triggered it).
            .confirmationDialog(
                "Delete \(selectedIds.count) item\(selectedIds.count == 1 ? "" : "s")?",
                isPresented: $showingBulkDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They'll move to the trash.")
            }
            // Registered alongside the existing `NavigationLink` rows
            // so programmatic pushes via `path.append(id)` open the
            // editor — driven by `composer.pendingOpenDoc` below.
            .navigationDestination(for: String.self) { docId in
                if let api = store.api {
                    DocumentView(vm: tabManager.open(docId: docId, api: api),
                                 onDisappear: store.load)
                        .navigationTransition(.zoom(sourceID: docId, in: docZoom))
                }
            }
        }
        .onChange(of: composer.pendingOpenDoc) { _, newValue in
            // Wait for the create sheet to finish dismissing before
            // pushing, otherwise SwiftUI can race the path update
            // against the sheet's exit transition and drop the push.
            guard let docId = newValue else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                path.append(docId)
                composer.pendingOpenDoc = nil
            }
        }
        .onChange(of: validPathKey) { _, _ in pruneStalePath() }
        .onReceive(NotificationCenter.default.publisher(
            for: Composer.popHomeNotification)) { _ in
            // Switcher's ✓ button posted this after dismissing with
            // zero tabs left. Direct @State mutation actually pops the
            // NavigationStack (a $model.path binding wouldn't).
            path.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Composer.popToDocNotification)) { note in
            // DocumentView breadcrumb tapped an ancestor — truncate
            // the NavStack path to keep entries up to (and including)
            // that doc, popping every descendant in one go.
            guard let target = note.userInfo?["docId"] as? String,
                  let idx = path.firstIndex(of: target) else { return }
            path = Array(path.prefix(idx + 1))
        }
        .onChange(of: path) { oldPath, newPath in
            // Mark every newly-pushed doc as "open" in the switcher.
            // We do it here (in response to an explicit path change),
            // NOT inside the NavigationLink destination — that closure
            // is re-evaluated every time SwiftUI re-renders the body,
            // which would re-add tabs the user just closed via the
            // switcher.
            if newPath.count > oldPath.count, let api = store.api {
                for docId in newPath where !oldPath.contains(docId) {
                    tabManager.markOpened(docId: docId, api: api)
                }
            }
            // When the user pops back to the home, drop any selection
            // SwiftUI's List might have carried over from the programmatic
            // push — otherwise the row that was just navigated to stays
            // visually "focused" (lighter background) until the next
            // unrelated tap.
            if newPath.isEmpty && editMode != .active && !selectedIds.isEmpty {
                selectedIds.removeAll()
            }
        }
        // Rename alert — native iOS style. `.tint(.primary)` is
        // placed AFTER the `.alert` modifier so it wraps the alert
        // (env modifiers in SwiftUI flow downward to attached
        // overlays). Buttons read `.primary` instead of the
        // TabView's accent.
        .alert("Rename note", isPresented: Binding(
            get: { renamingDoc != nil },
            set: { if !$0 { renamingDoc = nil } }
        )) {
            TextField("Title", text: $renameDraft)
            Button("Rename") {
                if let doc = renamingDoc {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        store.renameDocument(id: doc.id, newTitle: trimmed)
                    }
                }
                renamingDoc = nil
            }
            Button("Cancel", role: .cancel) { renamingDoc = nil }
        }
        .tint(.primary)
        // Belt-and-braces: clear any lingering selection every time
        // the home reappears (covers pops, tab switches, sheet
        // dismissals). The onChange above only fires when `path`
        // transitions; this catches the cases where SwiftUI rebuilt
        // the home with a non-empty selection already.
        .task {
            if editMode != .active && !selectedIds.isEmpty {
                selectedIds.removeAll()
            }
        }
    }

    /// Bulk delete every selected workspace item. Routes notes through
    /// `store.delete(id:)` and databases through `deleteDatabase(id:)`
    /// so each goes via its proper SQLite soft-delete path.
    ///
    /// Important : selection is cleared BEFORE we mutate the store.
    /// UICollectionView (under SwiftUI's List) refuses to coalesce an
    /// update where the selection set still references rows that just
    /// disappeared — that's the `NSInternalInconsistencyException` we
    /// saw on Sentry (APPLE-IOS-8). Clearing first lets the diff
    /// settle on the store changes alone.
    /// Recent strip items, ordered by **last-opened** (MRU), not by
    /// `updatedAt`. Reads from `tabManager.recentlyViewed` (kept up to
    /// date in `markOpened`) and resolves each id against the live
    /// store metadata. Deleted docs naturally drop out of the strip.
    /// Capped at the user's recent-count setting.
    private var recentlyViewedItems: [WorkspaceItem] {
        let byId = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })
        return tabManager.recentlyViewed
            .compactMap { byId[$0] }
            .prefix(settings.recentCount)
            .map { $0 }
    }

    /// Stringified snapshot of the two upstream collections that gate
    /// path validity. Used as the single `.onChange` trigger to avoid
    /// the "compiler unable to type-check in reasonable time" wall
    /// that two separate `.onChange` modifiers in the body hit.
    private var validPathKey: String {
        let docs = store.documents.map(\.id).joined(separator: ",")
        let tabs = tabManager.openTabs.map(\.docId).joined(separator: ",")
        return "\(docs)|\(tabs)"
    }

    /// Drops any doc on the nav stack that's either been deleted from
    /// the store (bulk Delete All) or removed from the open-tabs list
    /// (switcher's "Close all tabs"). Without this the user stays on a
    /// DocumentView for a doc they just declared gone — renders as a
    /// blank "Untitled" because vm.load has nothing to fetch.
    private func pruneStalePath() {
        let docs = Set(store.documents.map(\.id))
        let tabs = Set(tabManager.openTabs.map(\.docId))
        path = path.filter {
            docs.contains($0) && tabs.contains($0)
        }
    }

    private func deleteSelected() {
        let toDelete = store.items.filter { selectedIds.contains($0.id) }
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedIds.removeAll()
            editMode = .inactive
        }
        for item in toDelete {
            switch item {
            case .note(let d):      store.delete(id: d.id)
            case .database(let db): store.deleteDatabase(id: db.id)
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    @ViewBuilder
    func itemRow(_ item: WorkspaceItem, api: PinkhaApi) -> some View {
        switch item {
        case .note(let doc):
            NavigationLink(destination:
                DocumentView(vm: tabManager.open(docId: doc.id, api: api),
                             onDisappear: store.load)
                    .navigationTransition(.zoom(sourceID: doc.id, in: docZoom))
            ) {
                WorkspaceRow(item: item, displayDateIso: displayDate(for: item))
            }
            .matchedTransitionSource(id: doc.id, in: docZoom)
            // Apple Music-style long-press : the row floats as a
            // detached card preview, with Rename / Delete options
            // underneath. Tap on the row itself still navigates.
            .contextMenu {
                Button {
                    renameDraft = doc.titlePlain
                    renamingDoc = doc
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.primary)
                if !store.databases.isEmpty {
                    Button {
                        attachDocId = doc.id
                    } label: {
                        Label("Add to a database", systemImage: "tablecells.badge.ellipsis")
                    }
                    .tint(.primary)
                }
                Button(role: .destructive) {
                    store.delete(id: doc.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            } preview: {
                NoteCardPreview(doc: doc)
            }
        case .database(let db):
            NavigationLink(destination: DatabaseView(dbId: db.id, api: api,
                                                    onDisappear: store.load)) {
                WorkspaceRow(item: item, displayDateIso: displayDate(for: item))
            }
        }
    }

    /// Returns a greeting adapted to the time of day. Returns
    /// `LocalizedStringKey` (not `String`) so `.navigationTitle(_:)`
    /// picks the localized overload — a raw `String` would render
    /// verbatim and skip the catalog lookup.
    private var greeting: LocalizedStringKey {
        let h = Calendar.current.component(.hour, from: .now)
        switch h {
        case 5..<12: return "Good morning."
        case 12..<18: return "Good afternoon."
        default:      return "Good evening."
        }
    }
}
