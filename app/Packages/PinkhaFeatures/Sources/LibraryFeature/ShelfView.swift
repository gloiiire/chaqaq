import SwiftUI
import PinkhaFFI
import PinkhaCore
import PinkhaDesignSystem
import PinkhaComposer
import LeafFeature

// ── Shelf content view ───────────────────────────────────────────────────────

/// Shows the contents of a single shelf: its sub-shelves (Craft-style nesting)
/// then its leaves. Tapping a sub-shelf pushes another `ShelfView` onto
/// the same NavigationStack, giving arbitrary-depth navigation for free.
public struct ShelfView: View {
    public init(store: PinkhaStore, shelf: ShelfMetaFfi) {
        self.store = store
        self.shelf = shelf
    }
    @Bindable public var store: PinkhaStore
    public let shelf: ShelfMetaFfi
    /// Optional Composer — injected by `ContentView`. We read it to flip
    /// `currentContext` to this shelf on appear and back to `.root` on
    /// disappear, so the create bubble's "New …" land inside the shelf
    /// the user is looking at.
    @Environment(Composer.self) private var composer
    @Environment(TabManager.self) private var tabManager

    @State private var showingNewSubShelf = false
    @State private var newSubShelfName = ""
    @State private var showingRename = false
    @State private var renameDraft = ""
    @State private var showingEmojiPicker = false
    @State private var recentEmojis: [String] = loadRecentEmojis()
    /// Leaf rename state owned at the ShelfView level so the
    /// long-press menu inside a leaf row can present a centered
    /// `.alert` — alerts attached inside a `.contextMenu` builder
    /// don't fire on iOS 26.
    @State private var shelfLeafRenaming: LeafMetaFfi?
    @State private var shelfLeafRenameDraft = ""
    /// Leaf id awaiting the "Add to a book" sheet — same reason as
    /// above, alerts/sheets inside `.contextMenu` lose their binding
    /// when the menu dismisses.
    @State private var shelfLeafAttachId: String?
    /// Cascade delete confirmation state. Sub-shelf swipe + toolbar
    /// Delete both stage their target here ; the single
    /// `.shelfDeleteDialog` attached to the `List` root below presents.
    @State private var pendingShelfDeletion: ShelfMetaFfi?
    /// Per-shelf sort key for the sub-shelves section. Each `ShelfView`
    /// gets its own persisted preference in `UserDefaults`, keyed by
    /// the shelf id — different shelves can have different sub-section
    /// sorts. `@State` plus manual `UserDefaults` read/write because
    /// `@AppStorage` only accepts literal string keys.
    @State private var subShelfSortKeyRaw: String = LibraryView.ShelfSortKey.manual.rawValue
    @State private var subShelfSortAsc: Bool = false
    private var subShelfSortDefaultsKey: String { "shelves.sortKey.\(shelf.id)" }
    private var subShelfSortAscDefaultsKey: String { "shelves.sortAsc.\(shelf.id)" }
    private var subShelfSortKey: LibraryView.ShelfSortKey {
        LibraryView.ShelfSortKey(rawValue: subShelfSortKeyRaw) ?? .manual
    }
    private func loadSubShelfSortKey() {
        if let saved = UserDefaults.standard.string(forKey: subShelfSortDefaultsKey) {
            subShelfSortKeyRaw = saved
        } else {
            subShelfSortKeyRaw = LibraryView.ShelfSortKey.manual.rawValue
        }
        subShelfSortAsc = UserDefaults.standard.bool(forKey: subShelfSortAscDefaultsKey)
    }
    private func pickSubShelfSort(_ key: LibraryView.ShelfSortKey) {
        subShelfSortKeyRaw = key.rawValue
        UserDefaults.standard.set(key.rawValue, forKey: subShelfSortDefaultsKey)
    }
    private func pickSubShelfSortOrder(_ asc: Bool) {
        subShelfSortAsc = asc
        UserDefaults.standard.set(asc, forKey: subShelfSortAscDefaultsKey)
    }
    private func subShelfMoveHandler(current: [ShelfMetaFfi]) -> ((IndexSet, Int) -> Void)? {
        guard subShelfSortKey == .manual else { return nil }
        return { source, destination in
            var ids = current.map(\.id)
            ids.move(fromOffsets: source, toOffset: destination)
            store.setShelvesManualOrder(orderedIds: ids)
        }
    }

    /// Most up-to-date copy of `shelf` so a rename / icon update reflects
    /// without popping back to the parent view. Re-derived from the store
    /// on each render — `store.listShelves()` is cheap (in-memory cache).
    private var current: ShelfMetaFfi {
        store.listShelves().first(where: { $0.id == shelf.id }) ?? shelf
    }

    public var body: some View {
        let subShelves = sortShelves(store.childShelves(of: shelf.id),
                                     by: subShelfSortKey,
                                     ascending: subShelfSortAsc)
        let docs = store.documentsInShelf(shelfId: shelf.id)

        List {
            // ── Sub-shelves ───────────────────────────────────────────────
            Section {
                ForEach(subShelves, id: \.id) { sub in
                    NavigationLink(value: LibraryRoute.shelf(sub.id)) {
                        ShelfRow(store: store, shelf: sub) { target in
                            pendingShelfDeletion = target
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingShelfDeletion = sub
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
                .onMove(perform: subShelfMoveHandler(current: subShelves))

                Button {
                    newSubShelfName = ""
                    showingNewSubShelf = true
                } label: {
                    Label("New sub-shelf", systemImage: "books.vertical.fill")
                        .foregroundStyle(.tint)
                }
            } header: {
                ShelvesSectionHeader(
                    title: "Shelves",
                    sortKey: subShelfSortKey,
                    sortAsc: subShelfSortAsc,
                    onPick: pickSubShelfSort,
                    onPickOrder: pickSubShelfSortOrder
                )
            }

            // ── Leaves ─────────────────────────────────────────────────
            Section {
                if docs.isEmpty {
                    Text("No leaves in this shelf yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else if store.api != nil {
                    ForEach(docs, id: \.id) { doc in
                        NavigationLink(value: LibraryRoute.leaf(doc.id)) {
                            LibraryRow(item: .leaf(doc), store: store)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.delete(id: doc.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                        .leafContextMenu(
                            doc: doc,
                            store: store,
                            onRename: {
                                shelfLeafRenameDraft = doc.titlePlain
                                shelfLeafRenaming = doc
                            },
                            onAttachToBook: {
                                shelfLeafAttachId = doc.id
                            }
                        )
                    }
                }
            } header: {
                SectionHeader(title: "Leaves")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Overflow menu : rename, set/clear icon. The icon picker
            // re-uses the same EmojiPickerSheet as leaves so the
            // experience stays consistent across the library.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameDraft = current.name
                        showingRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.primary)
                    Button {
                        showingEmojiPicker = true
                    } label: {
                        Label(current.icon == nil ? "Set icon" : "Change icon",
                              systemImage: "face.smiling")
                    }
                    .tint(.primary)
                    if current.icon != nil {
                        Button(role: .destructive) {
                            store.updateShelfIcon(id: shelf.id, icon: nil)
                        } label: {
                            Label("Remove icon", systemImage: "xmark.circle")
                        }
                        .tint(.primary)
                    }
                    Divider()
                    Menu {
                        Button {
                            withAnimation {
                                store.moveShelf(id: shelf.id, newParentId: nil)
                                store.load()
                            }
                        } label: {
                            Label("Library root", systemImage: "books.vertical.fill")
                        }
                        .tint(.primary)
                        Divider()
                        let candidates = store.listShelves().filter { $0.id != shelf.id }
                        if candidates.isEmpty {
                            Text("No other shelves yet")
                        } else {
                            ForEach(candidates, id: \.id) { other in
                                Button {
                                    withAnimation {
                                        store.moveShelf(id: shelf.id, newParentId: other.id)
                                        store.load()
                                    }
                                } label: {
                                    Label(other.name, systemImage: "books.vertical.fill")
                                }
                                .tint(.primary)
                            }
                        }
                    } label: {
                        Label("Move to…", systemImage: "arrow.uturn.right.circle")
                    }
                    .tint(.primary)
                    Divider()
                    Button(role: .destructive) {
                        pendingShelfDeletion = current
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More actions")
            }
        }
        .onAppear {
            composer.currentContext = .shelf(id: shelf.id)
            loadSubShelfSortKey()
        }
        .onDisappear {
            // Same guard as LeafView.onDisappear : SwiftUI may
            // fire the destination's onAppear before our onDisappear,
            // so we only reset when the context is still ours.
            if composer.currentContext == .shelf(id: shelf.id) {
                composer.currentContext = .root
            }
        }
        .alert("New sub-shelf", isPresented: $showingNewSubShelf) {
            TextField("Name", text: $newSubShelfName)
            Button("Create") {
                let trimmed = newSubShelfName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                store.createShelf(name: trimmed, parentId: shelf.id)
                store.load()
                newSubShelfName = ""
            }
            Button("Cancel", role: .cancel) { newSubShelfName = "" }
        }
        .alert("Rename shelf", isPresented: $showingRename) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                store.renameShelf(id: shelf.id, newName: trimmed)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Rename leaf",
            isPresented: Binding(
                get: { shelfLeafRenaming != nil },
                set: { if !$0 { shelfLeafRenaming = nil } }
            )
        ) {
            TextField("Title", text: $shelfLeafRenameDraft)
            Button("Rename") {
                let trimmed = shelfLeafRenameDraft.trimmingCharacters(in: .whitespaces)
                if let doc = shelfLeafRenaming, !trimmed.isEmpty {
                    store.renameLeaf(id: doc.id, newTitle: trimmed)
                }
                shelfLeafRenaming = nil
            }
            Button("Cancel", role: .cancel) { shelfLeafRenaming = nil }
        }
        .sheet(
            item: Binding(
                get: { shelfLeafAttachId.map(BindLeafIdentifier.init) },
                set: { shelfLeafAttachId = $0?.id }
            )
        ) { wrapper in
            BindLeafToBookSheet(leafId: wrapper.id)
                .environment(store)
                .presentationDetents([.large])
        }
        .shelfDeleteDialog(pending: $pendingShelfDeletion, store: store)
        .sheet(isPresented: $showingEmojiPicker) {
            EmojiPickerSheet(selection: current.icon, recents: recentEmojis) { emoji in
                store.updateShelfIcon(id: shelf.id, icon: emoji)
                recentEmojis = saveRecentEmoji(emoji)
                showingEmojiPicker = false
            }
        }
    }

    /// Prepends the emoji to the navigation title when set, so the user
    /// sees their chosen icon at the top of the shelf view too.
    private var displayTitle: String {
        if let icon = current.icon, !icon.isEmpty {
            return "\(icon)  \(current.name)"
        }
        return current.name
    }
}

// ── Shelf row ────────────────────────────────────────────────────────────────

/// Row used by both `ShelfView` (sub-shelves) and `ShelvesSectionView`
/// (root-level shelves) — shows the emoji icon when set, falling back to
/// the system shelf symbol otherwise. Hosts the long-press context menu
/// (rename / icon / delete) and is both a drag source (`DraggedItem.shelf`)
/// and a drop destination (accepts `.leaf` to file a leaf into the shelf,
/// `.shelf` to nest a shelf inside another).
public struct ShelfRow: View {
    public init(store: PinkhaStore,
                shelf: ShelfMetaFfi,
                onDeleteRequest: ((ShelfMetaFfi) -> Void)? = nil) {
        self.store = store
        self.shelf = shelf
        self.onDeleteRequest = onDeleteRequest
    }
    @Bindable public var store: PinkhaStore
    public let shelf: ShelfMetaFfi
    /// Bubbled up to the row's host (LibraryView / ShelfView) which
    /// owns the cascade-delete confirmation dialog at the List root
    /// — Section / row level can't present a `confirmationDialog`.
    /// `nil` falls back to a direct `store.deleteShelf(id:)` (legacy
    /// callers like SearchView that don't need the dialog).
    public var onDeleteRequest: ((ShelfMetaFfi) -> Void)?

    @State private var showingRename = false
    @State private var renameDraft = ""
    @State private var showingEmojiPicker = false
    @State private var recentEmojis: [String] = loadRecentEmojis()

    public var body: some View {
        HStack(spacing: 12) {
            if let icon = shelf.icon, !icon.isEmpty {
                Text(icon).font(.title3).frame(width: 28)
            } else {
                Image(systemName: "books.vertical").foregroundStyle(.tint).frame(width: 28)
            }
            Text(shelf.name)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contextMenu {
            // Per-button `.tint(.primary)` for the neutral entries +
            // `.tint(.red)` on Delete — same norm as
            // `LeafContextMenuContent`. Without it iOS paints the icons
            // in the surrounding accent color.
            Button {
                renameDraft = shelf.name
                showingRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.primary)
            Button {
                showingEmojiPicker = true
            } label: {
                Label(shelf.icon == nil ? "Set icon" : "Change icon",
                      systemImage: "face.smiling")
            }
            .tint(.primary)
            if shelf.icon != nil {
                Button(role: .destructive) {
                    store.updateShelfIcon(id: shelf.id, icon: nil)
                } label: {
                    Label("Remove icon", systemImage: "xmark.circle")
                }
                .tint(.primary)
            }
            Divider()
            Menu {
                Button {
                    withAnimation {
                        store.moveShelf(id: shelf.id, newParentId: nil)
                        store.load()
                    }
                } label: {
                    Label("Library root", systemImage: "books.vertical.fill")
                }
                .tint(.primary)
                Divider()
                let candidates = store.listShelves().filter { $0.id != shelf.id }
                if candidates.isEmpty {
                    Text("No other shelves yet")
                } else {
                    ForEach(candidates, id: \.id) { other in
                        Button {
                            withAnimation {
                                store.moveShelf(id: shelf.id, newParentId: other.id)
                                store.load()
                            }
                        } label: {
                            Label(other.name, systemImage: "books.vertical.fill")
                        }
                        .tint(.primary)
                    }
                }
            } label: {
                Label("Move to…", systemImage: "arrow.uturn.right.circle")
            }
            .tint(.primary)
            Divider()
            Button(role: .destructive) {
                if let onDeleteRequest {
                    onDeleteRequest(shelf)
                } else {
                    store.deleteShelf(id: shelf.id)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        // Drag&drop disabled : neither the new Transferable
        // `.dropDestination` nor the legacy `.onDrop` work reliably
        // inside a `List` on iOS (FB12980427), and a UIKit wrap
        // imposes too much rewrite. Moves go through the
        // "Move to…" submenu in the long-press context menu above.
        .alert("Rename shelf", isPresented: $showingRename) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                store.renameShelf(id: shelf.id, newName: trimmed)
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingEmojiPicker) {
            EmojiPickerSheet(selection: shelf.icon, recents: recentEmojis) { emoji in
                store.updateShelfIcon(id: shelf.id, icon: emoji)
                recentEmojis = saveRecentEmoji(emoji)
                showingEmojiPicker = false
            }
        }
    }
}

// ── Shelves section ───────────────────────────────────────────────────────────

/// Section that lists top-level shelves in `LibraryView`. Mirrors the
/// PINNED section : trailing sort menu in the header (Manual / Name /
/// Created / Updated), `.onMove` enabled only when Manual is active.
public struct ShelvesSectionView: View {
    @Bindable public var store: PinkhaStore
    /// Sort key for the Library home's root SHELVES section. Distinct
    /// from each sub-shelf's preference (which is stored under
    /// `shelves.sortKey.<uuid>`) so the user can sort every section
    /// independently.
    @AppStorage("shelves.sortKey.root") private var sortKeyRaw: String = LibraryView.ShelfSortKey.manual.rawValue
    @AppStorage("shelves.sortAsc.root") private var sortAsc: Bool = false
    @Environment(AppSettings.self) private var settings
    @State private var showingNewShelf = false
    @State private var newShelfName = ""
    /// Bubbled UP to `LibraryView` because `confirmationDialog` can't
    /// present from inside a `Section` — Section isn't a presentation
    /// container, so attaching the dialog here makes it silently
    /// no-op. The caller (LibraryView) owns the state + dialog at the
    /// List / NavigationStack level where presentation actually works.
    public var onDeleteRequest: (ShelfMetaFfi) -> Void

    public init(store: PinkhaStore,
                onDeleteRequest: @escaping (ShelfMetaFfi) -> Void) {
        self.store = store
        self.onDeleteRequest = onDeleteRequest
    }

    private var sortKey: LibraryView.ShelfSortKey {
        LibraryView.ShelfSortKey(rawValue: sortKeyRaw) ?? .manual
    }

    public var body: some View {
        Section {
            ForEach(sortedShelves, id: \.id) { shelf in
                // Value-based push so the shelf lands in the parent
                // `LibraryView`'s `path` — mandatory for the
                // swipe-back fix.
                NavigationLink(value: LibraryRoute.shelf(shelf.id)) {
                    ShelfRow(store: store, shelf: shelf) { target in
                        onDeleteRequest(target)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        onDeleteRequest(shelf)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
            .onMove(perform: moveHandler)

            Button {
                showingNewShelf = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "books.vertical.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    Text("New Shelf").foregroundStyle(.tint)
                }
            }
        } header: {
            ShelvesSectionHeader(
                title: "Shelves",
                sortKey: sortKey,
                sortAsc: sortAsc,
                onPick: { key in sortKeyRaw = key.rawValue },
                onPickOrder: { asc in sortAsc = asc }
            )
        }
        .alert("New Shelf", isPresented: $showingNewShelf) {
            TextField("Name", text: $newShelfName)
            Button("Create") {
                guard !newShelfName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                store.createShelf(name: newShelfName)
                newShelfName = ""
            }
            Button("Cancel", role: .cancel) { newShelfName = "" }
        }
    }

    private var sortedShelves: [ShelfMetaFfi] {
        sortShelves(store.childShelves(of: nil), by: sortKey, ascending: sortAsc)
    }

    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard sortKey == .manual else { return nil }
        return { source, destination in
            var ids = sortedShelves.map(\.id)
            ids.move(fromOffsets: source, toOffset: destination)
            store.setShelvesManualOrder(orderedIds: ids)
        }
    }
}

/// Reusable sort header for the SHELVES (root + sub-shelves) sections.
/// Same shape as `LibraryView.pinnedSectionHeader` so the visual /
/// behavioural language is consistent.
struct ShelvesSectionHeader: View {
    let title: LocalizedStringKey
    let sortKey: LibraryView.ShelfSortKey
    let sortAsc: Bool
    let onPick: (LibraryView.ShelfSortKey) -> Void
    let onPickOrder: (Bool) -> Void

    var body: some View {
        HStack {
            SectionHeader(title: title)
            Spacer()
            Menu {
                Section("Sort by") {
                    ForEach(LibraryView.ShelfSortKey.allCases) { key in
                        Button { onPick(key) } label: {
                            ShelfSortRow(label: key.label,
                                         systemImage: key.systemImage,
                                         isSelected: sortKey == key)
                        }
                        .tint(.primary)
                    }
                }
                // Order picker hidden when Manual is active : the
                // hand-dragged arrangement IS the order.
                if sortKey != .manual {
                    Section("Order") {
                        Button { onPickOrder(true) } label: {
                            ShelfSortRow(label: "Ascending",
                                         systemImage: "arrow.up",
                                         isSelected: sortAsc)
                        }
                        .tint(.primary)
                        Button { onPickOrder(false) } label: {
                            ShelfSortRow(label: "Descending",
                                         systemImage: "arrow.down",
                                         isSelected: !sortAsc)
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
}

/// One row inside the SHELVES sort menu — same iOS workaround as
/// `LibraryView.pickerOption` : pre-bake the checkmark colour into a
/// UIImage so the tint survives the surrounding Menu.
private struct ShelfSortRow: View {
    let label: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Label {
            Text(label)
        } icon: {
            if isSelected {
                Image(uiImage: tintedSymbol("checkmark",
                                            color: UIColor(settings.accentColor)))
            } else {
                Image(systemName: systemImage)
            }
        }
    }
}

/// Sorts the input array by `key`. Manual orders by `manual_order`
/// (NULL after non-NULL), other keys fall back to the natural sort.
/// When `ascending` is true, the result is reversed (Manual ignores
/// the flag — the user's hand arrangement is the order). Shared
/// between root + sub-shelves sections so the comparator stays in
/// one place.
func sortShelves(_ shelves: [ShelfMetaFfi],
                 by key: LibraryView.ShelfSortKey,
                 ascending: Bool = false) -> [ShelfMetaFfi] {
    let base: [ShelfMetaFfi]
    switch key {
    case .manual:
        return shelves.sorted { a, b in
            switch (a.manualOrder, b.manualOrder) {
            case (let lhs?, let rhs?): return lhs < rhs
            case (_?, nil):            return true
            case (nil, _?):            return false
            case (nil, nil):           return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    case .name:
        base = shelves.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    case .createdAt:
        base = shelves.sorted { $0.createdAt > $1.createdAt }
    case .updatedAt:
        base = shelves.sorted { $0.updatedAt > $1.updatedAt }
    }
    return ascending ? base.reversed() : base
}
