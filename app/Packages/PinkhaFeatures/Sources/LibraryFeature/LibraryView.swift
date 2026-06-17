import SwiftUI
import PinkhaFFI
import PinkhaCore
import PinkhaDesignSystem
import PinkhaComposer
import LeafFeature
import BookFeature

// ── Tab 1: Library (unified) ──────────────────────────────────────────

/// Home screen for the Library tab — shows leaves and books in a unified list.
/// All creation / import / trash actions live in the global CreateBubble
/// hosted by `ContentView.tabViewBottomAccessory`, so this view focuses on
/// presenting the library content. Sibling files in this shelf own the
/// recent strip (`RecentStrip.swift`) and the list row (`LibraryRow.swift`).
public struct LibraryView: View {
    public init(store: PinkhaStore) {
        self.store = store
    }
    @Bindable public var store: PinkhaStore
    @Environment(Composer.self) var composer
    @Environment(AppSettings.self) var settings
    @Environment(TabManager.self) var tabManager
    @State private var showingSettings = false
    /// Programmatic navigation stack so a freshly-created leaf can be
    /// pushed onto the editor right after the create sheet dismisses
    /// — driven by `composer.pendingOpenDoc`. Must stay `@State` here :
    /// a binding sourced from `Composer` (observation-driven) hits a
    /// SwiftUI bug where `NavigationStack(path: $model.path)` does
    /// not visibly pop when `path.removeAll()` is called from outside.
    /// External mutations route through `Composer.popHomeNotification`.
    @State private var path: [LibraryRoute] = []
    /// Shared geometry namespace for the Apple Music / Books-style
    /// zoom transition when a doc card opens. Source views (list
    /// rows, Recent cards) tag themselves with
    /// `.matchedTransitionSource(id:in:)`; the destination LeafView
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
    @State private var renamingDoc: LeafMetaFfi?
    /// Book staged for the delete confirmation dialog (swipe on a
    /// book row) — the user decides whether its pages go with it.
    @State var pendingBookDeletion: BookMetaFfi?
    @State private var renameDraft: String = ""
    /// Doc currently picked through a "Add to a book" context
    /// menu item — drives the sheet below. `nil` = no sheet shown.
    @State var attachDocId: String?
    /// Root SHELVES cascade-delete state. Owned at this level (not
    /// inside `ShelvesSectionView`) because `confirmationDialog` can't
    /// present from inside a `Section` — the dialog must sit at the
    /// `List` / `NavigationStack` root to work.
    @State private var pendingShelfDeletion: ShelfMetaFfi?


    /// Sort + group preferences. `@AppStorage` persists them across
    /// launches without an explicit migration — each user setting maps
    /// to one `UserDefaults` key. Defaults mirror the previous implicit
    /// behaviour (most-recently-updated first, no grouping).
    @AppStorage("leaves.sortKey")   var sortKeyRaw: String = SortKey.updatedAt.rawValue
    @AppStorage("leaves.sortAsc")   var sortAscending: Bool = false
    @AppStorage("leaves.groupBy")   var groupByRaw: String = GroupBy.none.rawValue
    /// When on, books are hidden from the unified library list.
    /// The dedicated "Bases" tab still surfaces them — this flag only
    /// scopes the Library home view's mixed feed. Off by default.
    @AppStorage("leaves.hideBooks") var hideBooks: Bool = false
    /// Sort key for the PINNED section. Defaults to `.manual` so the
    /// drag-and-drop order is honoured ; users can pick any other key
    /// from the menu in the section header to fall back to a
    /// date-driven or alphabetical sort. Persisted independently of
    /// the All section's sort.
    @AppStorage("pinned.sortKey") var pinnedSortKeyRaw: String = PinnedSortKey.manual.rawValue
    /// Ascending vs descending for the PINNED section. Defaults to
    /// `false` (descending) so date-driven sorts surface the newest
    /// first ; Manual ignores this flag.
    @AppStorage("pinned.sortAsc") var pinnedSortAsc: Bool = false
    /// Sort key for the SHELVES section. Same defaults / behaviour as
    /// the PINNED key but with a smaller option set (shelves have no
    /// "Last opened" or "Published" surfaces).
    @AppStorage("shelves.sortKey") var shelvesSortKeyRaw: String = ShelfSortKey.manual.rawValue

    var sortKey: SortKey {
        SortKey(rawValue: sortKeyRaw) ?? .updatedAt
    }
    var groupBy: GroupBy {
        GroupBy(rawValue: groupByRaw) ?? .none
    }
    var pinnedSortKey: PinnedSortKey {
        PinnedSortKey(rawValue: pinnedSortKeyRaw) ?? .manual
    }
    var shelvesSortKey: ShelfSortKey {
        ShelfSortKey(rawValue: shelvesSortKeyRaw) ?? .manual
    }

    /// Sort options for the SHELVES section. Shelves don't have a
    /// "last opened" tracking or a publish date — the option set is
    /// smaller than `PinnedSortKey`. Reused by `ShelfView`'s
    /// sub-shelves section so both surfaces share the same vocabulary.
    public enum ShelfSortKey: String, CaseIterable, Identifiable {
        case manual, name, createdAt, updatedAt
        public var id: String { rawValue }
        public var label: LocalizedStringKey {
            switch self {
            case .manual:    "Manual"
            case .name:      "Name"
            case .createdAt: "Created"
            case .updatedAt: "Updated"
            }
        }
        public var systemImage: String {
            switch self {
            case .manual:    "hand.draw"
            case .name:      "textformat"
            case .createdAt: "calendar.badge.plus"
            case .updatedAt: "calendar"
            }
        }
    }

    enum PinnedSortKey: String, CaseIterable, Identifiable {
        case manual, lastOpened, name, createdAt, updatedAt, publishedAt
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .manual:      "Manual"
            case .lastOpened:  "Last opened"
            case .name:        "Name"
            case .createdAt:   "Created"
            case .updatedAt:   "Updated"
            case .publishedAt: "Published"
            }
        }
        var systemImage: String {
            switch self {
            case .manual:      "hand.draw"
            case .lastOpened:  "clock"
            case .name:        "textformat"
            case .createdAt:   "calendar.badge.plus"
            case .updatedAt:   "calendar"
            case .publishedAt: "paperplane"
            }
        }
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

    private var bulkDeleteConfirmTitle: String {
        let n = selectedIds.count
        return "Delete \(n) item\(n == 1 ? "" : "s")?"
    }

    @ViewBuilder
    private var listContent: some View {
        if !recentlyViewedItems.isEmpty {
            Section {
                RecentStrip(
                    items: recentlyViewedItems,
                    api: store.api,
                    zoomNamespace: docZoom,
                    onDisappear: { store.load() },
                    onOpenLeaf: { leafId in
                        path.append(.leaf(leafId))
                    },
                    onRenameLeaf: { doc in
                        renameDraft = doc.titlePlain
                        renamingDoc = doc
                    },
                    onDeleteLeaf: { doc in
                        store.delete(id: doc.id)
                    },
                    onAddToBook: store.books.isEmpty ? nil : { doc in
                        attachDocId = doc.id
                    },
                    availableShelves: store.listShelves(),
                    onMoveLeafToShelf: { doc, shelfId in
                        withAnimation {
                            store.moveLeafToShelf(leafId: doc.id, shelfId: shelfId)
                            store.load()
                        }
                    },
                    onSetLeafPinned: { doc, pinned in
                        withAnimation {
                            store.setLeafPinned(leafId: doc.id, pinned: pinned)
                        }
                    }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            } header: {
                SectionHeader(title: "Recent")
            }
        }

        // Pinned section : sits between Recent and Shelves so the
        // user's hand-picked must-keep-around leaves stay above the
        // generic library. Hidden when no leaf is pinned.
        pinnedSection

        if !store.listShelves().isEmpty {
            ShelvesSectionView(store: store) { shelf in
                pendingShelfDeletion = shelf
            }
        }

        if store.items.isEmpty {
            Section {
                LibraryEmptyState()
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

    /// Toolbar content extracted out of the main `body` because the
    /// nested `ToolbarItem` / `Button` / conditional chains push Swift's
    /// type-checker past its budget on the iOS 26 SDK when inlined.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
                // primary bulk-delete action. Bottom-bar placement
                // collides with the TabView's search bubble, so we
                // surface the action up here.
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

    /// Conditional selection binding — we only let the List track
    /// selection while edit mode is active. Outside of it,
    /// `selectedIds` is forced to empty (writes are dropped), which
    /// prevents the iOS 26 default behaviour of leaving a
    /// NavigationLink-pushed row visually "focused" after the user
    /// pops back. Extracted as a computed property because inlining
    /// the `Binding(get:set:)` in `List(selection:)` blows past Swift's
    /// type-checker timeout budget on iOS 26 SDK.
    private var selectionBinding: Binding<Set<String>> {
        Binding(
            get: { editMode == .active ? selectedIds : [] },
            set: { newValue in
                if editMode == .active { selectedIds = newValue }
            }
        )
    }

    /// Single binding for the "Bind to a book" sheet — needs to be a
    /// `Binding<Item?>` so the sheet's `item:` overload fires the
    /// right open/close transitions. Extracted out of body to keep
    /// the chain Swift's type checker can crunch.
    private var attachSheetItemBinding: Binding<BindLeafIdentifier?> {
        Binding(
            get: { attachDocId.map(BindLeafIdentifier.init) },
            set: { attachDocId = $0?.id }
        )
    }

    /// The whole List + every chained modifier (style, tint,
    /// environment, navigation title, edge effects, dialogs, toolbar,
    /// sheets, navigationDestination). Inlined this used to blow past
    /// Swift's type-checker budget on iOS 26 SDK — broken out here so
    /// `body` only handles the NavigationStack wrapper and the global
    /// `onChange/onReceive` notifications.
    @ViewBuilder
    private var stackContent: some View {
        List(selection: selectionBinding) {
            listContent
        }
        .listStyle(.insetGrouped)
        // Re-tint the List with the accent so the edit-mode
        // selection circles stay readable. Without this they'd
        // inherit the `.tint(.primary)` set just before the rename
        // alert later in the chain and render white.
        .tint(settings.accentColor)
        .environment(\.editMode, $editMode)
        .navigationTitle(greeting)
        .navigationBarTitleDisplayMode(.large)
        // iOS 26 : let the list edges fade under the large title and
        // the bottom accessory bar so the chrome floats above the
        // content instead of slamming a solid bar over it.
        .scrollEdgeEffectStyle(.soft, for: .all)
        .databaseDeleteDialog(pending: $pendingBookDeletion, store: store)
        .shelfDeleteDialog(pending: $pendingShelfDeletion, store: store)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        // Surfaced from the "Add to a book" long-press menu on leaf
        // rows / recents — files the existing doc as a row of the
        // picked book with the title pre-seeded.
        .sheet(item: attachSheetItemBinding) { wrapper in
            BindLeafToBookSheet(leafId: wrapper.id)
                .environment(store)
                .presentationDetents([.large])
        }
        // Native confirmation dialog before the bulk delete fires —
        // matches the Apple Notes / Mail pattern (slide-up sheet
        // anchored to the row that triggered it).
        .confirmationDialog(
            bulkDeleteConfirmTitle,
            isPresented: $showingBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll move to the trash.")
        }
        // Single typed destination for both leaves and shelves so
        // every drill-in goes through `path` — previously shelves
        // were closure-pushed, which broke the swipe-back from a
        // leaf created inside a shelf (the system would rebuild the
        // stack to honour the path and drop the closure-pushed
        // shelf). Switch on the case to pick the right destination.
        .navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case .leaf(let leafId):
                if let api = store.api {
                    LeafView(vm: tabManager.open(leafId: leafId, api: api),
                             onDisappear: store.load)
                        .navigationTransition(.zoom(sourceID: leafId, in: docZoom))
                }
            case .shelf(let shelfId):
                if let shelf = store.listShelves().first(where: { $0.id == shelfId }) {
                    ShelfView(store: store, shelf: shelf)
                        .navigationTransition(.zoom(sourceID: shelfId, in: docZoom))
                }
            }
        }
    }

    public var body: some View {
        NavigationStack(path: $path) {
            stackContent
        }
        .onChange(of: composer.pendingOpenDoc) { _, newValue in
            // Wait for the create sheet to finish dismissing before
            // pushing, otherwise SwiftUI can race the path update
            // against the sheet's exit transition and drop the push.
            guard let leafId = newValue else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                path.append(.leaf(leafId))
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
            // LeafView breadcrumb tapped an ancestor — truncate
            // the NavStack path to keep entries up to (and including)
            // that doc, popping every descendant in one go.
            guard let target = note.userInfo?["leafId"] as? String,
                  let idx = path.firstIndex(of: .leaf(target)) else { return }
            path = Array(path.prefix(idx + 1))
        }
        .onChange(of: path) { oldPath, newPath in
            // Mark every newly-pushed leaf as "open" in the switcher.
            // We do it here (in response to an explicit path change),
            // NOT inside the NavigationLink destination — that closure
            // is re-evaluated every time SwiftUI re-renders the body,
            // which would re-add tabs the user just closed via the
            // switcher. Shelves don't have a tab representation, so
            // we skip them.
            if newPath.count > oldPath.count, let api = store.api {
                for route in newPath where !oldPath.contains(route) {
                    if case .leaf(let leafId) = route {
                        tabManager.markOpened(leafId: leafId, api: api)
                    }
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
        .alert("Rename leaf", isPresented: renamingBinding) {
            TextField("Title", text: $renameDraft)
            Button("Rename") { commitRename() }
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

    /// Bulk delete every selected library item. Routes leaves through
    /// `store.delete(id:)` and books through `deleteBook(id:)`
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
    /// The PINNED section, extracted out of `listContent` because the
    /// inline expression became too complex for the SwiftUI type
    /// checker once the section gained its own sort menu and
    /// conditional `.onMove`. `EmptyView()` when nothing's pinned —
    /// `@ViewBuilder` flattens it cleanly.
    @ViewBuilder
    private var pinnedSection: some View {
        if !sortedPinnedLeaves.isEmpty, store.api != nil {
            Section {
                ForEach(sortedPinnedLeaves, id: \.id) { doc in
                    NavigationLink(value: LibraryRoute.leaf(doc.id)) {
                        LibraryRow(item: .leaf(doc), store: store)
                    }
                    .matchedTransitionSource(id: doc.id, in: docZoom)
                    .leafContextMenu(
                        doc: doc,
                        store: store,
                        onRename: {
                            renameDraft = doc.titlePlain
                            renamingDoc = doc
                        },
                        onAttachToBook: {
                            attachDocId = doc.id
                        }
                    )
                }
                // `.onMove` is only attached when the user opted into
                // Manual sort. In any other mode the drag handle would
                // produce a reorder the next `load()` would immediately
                // overwrite with the date / name ordering.
                .onMove(perform: pinnedMoveHandler)
            } header: {
                pinnedSectionHeader
            }
        }
    }

    /// Pinned leaves sorted by the active `pinnedSortKey`. Defaults
    /// to `.manual` which preserves the drag-and-drop order stored on
    /// `LeafMeta.manualOrder`. Other modes (`updatedAt`, `createdAt`,
    /// etc.) re-sort the same set on top of `store.pinnedLeaves` —
    /// the manual indexes stay persisted so switching back to Manual
    /// returns to the previous arrangement.
    private var sortedPinnedLeaves: [LeafMetaFfi] {
        let pinned = store.pinnedLeaves
        let base: [LeafMetaFfi]
        switch pinnedSortKey {
        case .manual:
            // Manual ignores asc/desc — the user's hand-arranged order
            // already encodes their preference. Toggling asc/desc
            // would silently reverse the array, which is surprising.
            return pinned
        case .lastOpened:
            let openOrder = tabManager.recentlyViewed
            let opened = openOrder.compactMap { id in pinned.first { $0.id == id } }
            let unopened = pinned.filter { p in !openOrder.contains(p.id) }
            base = opened + unopened
        case .name:
            base = pinned.sorted { $0.titlePlain.localizedCaseInsensitiveCompare($1.titlePlain) == .orderedAscending }
        case .createdAt:
            base = pinned.sorted { $0.createdAt > $1.createdAt }
        case .updatedAt:
            base = pinned.sorted { $0.updatedAt > $1.updatedAt }
        case .publishedAt:
            base = pinned.sorted { p1, p2 in
                let a = p1.publishedAt.isEmpty ? p1.createdAt : p1.publishedAt
                let b = p2.publishedAt.isEmpty ? p2.createdAt : p2.publishedAt
                return a > b
            }
        }
        // Default of each `base` is the descending / natural order ;
        // asc reverses for the user.
        return pinnedSortAsc ? base.reversed() : base
    }

    /// Reorder handler for the PINNED `.onMove`. Captures the new
    /// arrangement and persists it as the manual order. Only wired
    /// when `pinnedSortKey == .manual`.
    private func movePinned(_ source: IndexSet, _ destination: Int) {
        var ids = sortedPinnedLeaves.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        store.setLeavesManualOrder(orderedIds: ids)
    }

    /// Returns the move closure only when Manual sort is active.
    /// SwiftUI's `.onMove(perform:)` takes an optional closure ; when
    /// it's `nil` the system hides the reorder handle automatically.
    /// Extracted out of the call site so the inline ternary doesn't
    /// blow past Swift's type-check budget for the whole expression.
    private var pinnedMoveHandler: ((IndexSet, Int) -> Void)? {
        guard pinnedSortKey == .manual else { return nil }
        return { source, destination in
            movePinned(source, destination)
        }
    }

    /// Section header for PINNED with a trailing `arrow.up.arrow.down`
    /// menu — same affordance as the toolbar sort picker, scoped to
    /// the pinned set only. Tapping picks a sort mode ; the current
    /// mode is marked with a checkmark.
    private var pinnedSectionHeader: some View {
        HStack {
            SectionHeader(title: "Pinned")
            Spacer()
            Menu {
                Section("Sort by") {
                    ForEach(PinnedSortKey.allCases) { key in
                        Button {
                            pinnedSortKeyRaw = key.rawValue
                        } label: {
                            pickerOption(
                                label: key.label,
                                systemImage: key.systemImage,
                                isSelected: pinnedSortKey == key
                            )
                        }
                        .tint(.primary)
                    }
                }
                // Order picker — hidden when Manual is active, because
                // the manual arrangement already encodes the user's
                // direction and a silent reverse would be surprising.
                if pinnedSortKey != .manual {
                    Section("Order") {
                        Button { pinnedSortAsc = true } label: {
                            pickerOption(label: "Ascending",
                                         systemImage: "arrow.up",
                                         isSelected: pinnedSortAsc)
                        }
                        .tint(.primary)
                        Button { pinnedSortAsc = false } label: {
                            pickerOption(label: "Descending",
                                         systemImage: "arrow.down",
                                         isSelected: !pinnedSortAsc)
                        }
                        .tint(.primary)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
    }

    private var recentlyViewedItems: [WorkspaceItem] {
        // Lookup against `allItems` (every leaf, including those filed
        // inside a shelf) rather than `items` (root only) — Recent
        // should surface activity regardless of where the user filed
        // the leaf.
        let byId = Dictionary(uniqueKeysWithValues: store.allItems.map { ($0.id, $0) })
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
        let docs = store.allLeaves.map(\.id).joined(separator: ",")
        let shvs = store.shelves.map(\.id).joined(separator: ",")
        let tabs = tabManager.openTabs.map(\.leafId).joined(separator: ",")
        return "\(docs)|\(shvs)|\(tabs)"
    }

    /// Drops any leaf or shelf on the nav stack that's either been
    /// deleted from the store (bulk Delete All / Empty Trash) or
    /// removed from the open-tabs list (switcher's "Close all tabs").
    /// Without this the user stays on a destination for an entity they
    /// just declared gone — leaves render as a blank "Untitled" because
    /// the VM's `load` has nothing to fetch ; shelves throw the
    /// `first(where:)` lookup in `.navigationDestination`.
    private func pruneStalePath() {
        // `allLeaves` (every leaf, including shelf-filed) so children
        // pushed from a shelf aren't pruned the second their shelf is
        // mounted on the stack — those are still valid pages.
        let docs = Set(store.allLeaves.map(\.id))
        let shvs = Set(store.shelves.map(\.id))
        let tabs = Set(tabManager.openTabs.map(\.leafId))
        path = path.filter { route in
            switch route {
            case .leaf(let id):  return docs.contains(id) && tabs.contains(id)
            case .shelf(let id): return shvs.contains(id)
            }
        }
    }

    /// Binding for the rename alert's `isPresented` — extracted out
    /// of the body chain because the inline `Binding(get:set:)` plus
    /// the rename closure pushed the SwiftUI type-checker over its
    /// budget after the `LibraryRoute` refactor widened the path type.
    private var renamingBinding: Binding<Bool> {
        Binding(
            get: { renamingDoc != nil },
            set: { if !$0 { renamingDoc = nil } }
        )
    }

    /// Commits the in-flight rename draft. Same reason as the binding
    /// above — pulled out to keep the alert's button closure trivial.
    private func commitRename() {
        defer { renamingDoc = nil }
        guard let doc = renamingDoc else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.renameLeaf(id: doc.id, newTitle: trimmed)
    }

    private func deleteSelected() {
        let toDelete = store.items.filter { selectedIds.contains($0.id) }
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedIds.removeAll()
            editMode = .inactive
        }
        for item in toDelete {
            switch item {
            case .leaf(let d):      store.delete(id: d.id)
            case .book(let db): store.deleteBook(id: db.id)
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    @ViewBuilder
    func itemRow(_ item: WorkspaceItem, api: PinkhaApi) -> some View {
        switch item {
        case .leaf(let doc):
            NavigationLink(value: LibraryRoute.leaf(doc.id)) {
                LibraryRow(item: item, displayDateIso: displayDate(for: item), store: store)
            }
            .matchedTransitionSource(id: doc.id, in: docZoom)
            // Apple-Music-style long-press : the row floats as a
            // detached card preview, with the full leaf actions
            // (Rename / Pin / Add to a book / Move to shelf… / Delete)
            // underneath. Same menu lives in `ShelfView`'s leaf rows
            // and the Pinned section — `LeafContextMenuContent` is
            // the single source of truth.
            .contextMenu {
                LeafContextMenuContent(
                    doc: doc,
                    store: store,
                    onRename: {
                        renameDraft = doc.titlePlain
                        renamingDoc = doc
                    },
                    onAttachToBook: {
                        attachDocId = doc.id
                    }
                )
            } preview: {
                LeafCardPreview(doc: doc)
            }
        case .book(let db):
            NavigationLink(destination: BookView(bookId: db.id, api: api,
                                                    onDisappear: store.load)) {
                LibraryRow(item: item, displayDateIso: displayDate(for: item), store: store)
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
