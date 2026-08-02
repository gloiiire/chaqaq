import SwiftUI
import PinkhaFFI

// ── Store ─────────────────────────────────────────────────────────────────────

// `WorkspaceItem` moved to PinkhaCore (Phase 4A) so the UIKit bridge
// targets can reference it without depending on the app target. Same
// shape as before, only the home module changes.

/// Observable store that owns the `PinkhaApi` connection and the full library (leaves + books).
@MainActor
@Observable
public final class PinkhaStore {
    public var leaves: [LeafMetaFfi] = []
    /// Every leaf in the library regardless of where it's been filed —
    /// root-level, in a shelf, even nested as a child leaf. Used by the
    /// Recent strip and the Pinned section, which both surface activity
    /// across the whole library rather than just the "All" root list.
    public var allLeaves: [LeafMetaFfi] = []
    public var books: [BookMetaFfi] = []
    /// Cached shelves. **Must** sit in a tracked `@Observable` property
    /// so views that show shelves (`ShelvesSectionView`, `ShelfView`,
    /// the long-press "Move to…" submenu) re-evaluate when `load()`
    /// runs. Previously the accessors did direct FFI calls returning
    /// fresh arrays each time, which SwiftUI couldn't observe — the
    /// list never refreshed after a move until the view fully unmounted.
    public var shelves: [ShelfMetaFfi] = []
    public var errorMessage: String?
    /// `true` when the Inbox tab has at least one item awaiting the user's
    /// attention — flips the tab icon to `tray.badge.fill`. Wired manually
    /// for now (no real notification source yet); future imports / shared
    /// items / sync events can flip this.
    public var hasInboxNotification: Bool = false

    @ObservationIgnored public private(set) var api: PinkhaApi?

    public init() {}

    /// All library items merged and sorted by most recently updated.
    public var items: [WorkspaceItem] {
        let leafItems = leaves.map { WorkspaceItem.leaf($0) }
        let dbs   = books.map { WorkspaceItem.book($0) }
        return (leafItems + dbs).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The N most recently updated items for the recent strip,
    /// where N is the user's `AppSettings.recentCount` (default 7,
    /// bounded 5–20). Caller supplies the count so PinkhaStore stays
    /// independent of `AppSettings`.
    public func recentItems(limit: Int) -> [WorkspaceItem] {
        Array(items.prefix(limit))
    }

    /// Opens the SQLite book and seeds it when running under UI-test launch arguments.
    public func connect() {
        guard api == nil else { return }
        tryCatch(into: &errorMessage) {
            // UI-test modes: ephemeral DB for reproducibility.
            let args = ProcessInfo.processInfo.arguments
            let isUITest = args.contains("--ui-test-data") || args.contains("--ui-test-clean")
            // Application Support, not Documents — the database holds every
            // note in plaintext and Documents is exposed in the Files app by
            // `UIFileSharingEnabled`. `databasePath()` also relocates a
            // pre-existing database on the first launch after the move.
            let path = isUITest
                ? try DatabaseLocation.ephemeralDatabasePath()
                : try DatabaseLocation.databasePath()
            api = try PinkhaApi(dbPath: path)
            if args.contains("--ui-test-data") {
                _ = try api?.createLeaf(title: "Seeded Leaf 2")
                _ = try api?.createLeaf(title: "Seeded Leaf 1")
            }
            // --ui-test-clean: empty ephemeral DB, ideal for testing the empty state.
        }
        if api != nil { load() }
    }

    /// Refreshes leaves and books from the SQLite store. Loads both
    /// `leaves` (root-only — drives the "All" section in the home view)
    /// and `allLeaves` (every leaf regardless of filing — drives the
    /// Recent strip and the Pinned section), in addition to books.
    public func load() {
        if let docs = tryCatch(into: &errorMessage, { try api?.listRootLeaves() ?? [] }) {
            leaves = docs
        }
        if let everyDoc = tryCatch(into: &errorMessage, { try api?.listLeaves() ?? [] }) {
            allLeaves = everyDoc
        }
        if let dbs = tryCatch(into: &errorMessage, { try api?.listBooks() ?? [] }) {
            books = dbs
        }
        if let shvs = tryCatch(into: &errorMessage, { try api?.listShelves() ?? [] }) {
            shelves = shvs
        }
    }

    /// Same shape as `items` but built from `allLeaves` instead of just
    /// the root-level `leaves`. Used by the Recent strip, which must
    /// surface activity from any location — including leaves currently
    /// filed in a shelf.
    public var allItems: [WorkspaceItem] {
        let leafItems = allLeaves.map { WorkspaceItem.leaf($0) }
        let dbs   = books.map { WorkspaceItem.book($0) }
        return (leafItems + dbs).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Pinned leaves across the entire library. Sorted by
    /// `manualOrder` ascending when set (the user has manually
    /// reordered them via drag&drop), falling back to `pinnedAt`
    /// descending otherwise. Mixed states stay stable : pins with a
    /// manual index always sort before pins without one, so newly
    /// pinned leaves slot at the end of the manual list and can then
    /// be dragged into place.
    public var pinnedLeaves: [LeafMetaFfi] {
        let pinned = allLeaves.filter { ($0.pinnedAt ?? "").isEmpty == false }
        return pinned.sorted { a, b in
            switch (a.manualOrder, b.manualOrder) {
            case (let lhs?, let rhs?): return lhs < rhs
            case (_?, nil):            return true
            case (nil, _?):            return false
            case (nil, nil):           return (a.pinnedAt ?? "") > (b.pinnedAt ?? "")
            }
        }
    }

    /// Pins or unpins a leaf. `true` adds it to the home view's PINNED
    /// section ; `false` removes it. Reloads after the write so the
    /// section's visibility updates instantly.
    public func setLeafPinned(leafId: String, pinned: Bool) {
        tryCatch(into: &errorMessage) {
            try api?.setLeafPinned(id: leafId, pinned: pinned)
        }
        load()
    }

    /// Persists a new manual order for `orderedIds` — first id gets
    /// `manual_order = 0`, second gets 1, etc. Called by the
    /// drag-and-drop reorder UI (Pinned section, "Manual" sort mode
    /// in All section).
    public func setLeavesManualOrder(orderedIds: [String]) {
        tryCatch(into: &errorMessage) {
            try api?.setLeavesManualOrder(orderedIds: orderedIds)
        }
        load()
    }

    /// Persists a new manual order for shelves. Parallel to
    /// `setLeavesManualOrder` — first id gets `manual_order = 0`, etc.
    /// Used by the SHELVES section drag-and-drop reorder.
    public func setShelvesManualOrder(orderedIds: [String]) {
        tryCatch(into: &errorMessage) {
            try api?.setShelvesManualOrder(orderedIds: orderedIds)
        }
        load()
    }

    /// Direct child leaves of a given parent leaf. Used by the leaf
    /// view to surface sub-pages even when they aren't placed inline as
    /// `BlockContent::Page` blocks yet.
    public func childLeaves(of parentLeafId: String) -> [LeafMetaFfi] {
        guard let api else { return [] }
        return (try? api.listChildLeaves(parentLeafId: parentLeafId)) ?? []
    }

    /// Moves a leaf under another parent leaf, or to root when
    /// `newParentLeafId` is `nil`.
    public func moveLeafToParent(leafId: String, newParentLeafId: String?) {
        tryCatch(into: &errorMessage) {
            try api?.updateLeafParent(leafId: leafId, newParentLeafId: newParentLeafId)
        }
        load()
    }

    /// Creates a new leaf at the library root and reloads.
    /// Context-aware overloads (shelf / inside a doc / with a
    /// `StandaloneStyle`) live in `PinkhaStore+Composer.swift` in the
    /// Library layer so PinkhaCore stays independent of the
    /// feature-layer `Composer.CreationContext` and
    /// `StandaloneStyle` types.
    public func create(title: String) {
        guard let api else { return }
        tryCatch(into: &errorMessage) {
            _ = try api.createLeaf(title: title)
        }
        load()
    }

    /// Creates a new book at the library root and reloads. See
    /// `create(title:)` for the rationale; the context-aware overload
    /// lives in the Library-layer extension.
    public func createBook(title: String) {
        guard let api else { return }
        tryCatch(into: &errorMessage) {
            _ = try api.createBook(title: title)
        }
        load()
    }

    /// Renames a leaf (updates its title) and reloads so the home
    /// list reflects the new value.
    public func renameLeaf(id: String, newTitle: String) {
        if tryCatch(into: &errorMessage, {
            try api?.updateLeafTitle(id: id, newTitle: newTitle)
        }) != nil {
            load()
        }
    }

    /// Soft-deletes a leaf by id and reloads.
    public func delete(id: String) {
        if tryCatch(into: &errorMessage, { try api?.deleteLeaf(id: id) }) != nil {
            load()
        }
    }

    /// Soft-deletes all leaves and reloads.
    public func deleteAll() {
        if tryCatch(into: &errorMessage, { try api?.deleteAllLeaves() }) != nil {
            load()
        }
    }

    /// Soft-deletes all books and reloads.
    public func deleteAllBooks() {
        if tryCatch(into: &errorMessage, { try api?.deleteAllBooks() }) != nil {
            load()
        }
    }

    /// Soft-deletes all shelves (orphan contents fall back to root).
    /// Used by the "Delete all" flow so a clean wipe includes shelves.
    public func deleteAllShelves() {
        if tryCatch(into: &errorMessage, { try api?.deleteAllShelves() }) != nil {
            load()
        }
    }

    /// Soft-deletes a book AND every leaf its rows are backed
    /// by — the "Delete book & its pages" path of the delete dialog.
    /// Returns the number of leaves trashed alongside the book.
    @discardableResult
    public func deleteBookCascade(id: String) -> Int {
        let n = tryCatch(into: &errorMessage) { try api?.deleteBookCascade(id: id) ?? 0 } ?? 0
        load()
        return Int(n)
    }

    /// Restores a soft-deleted book AND every leaf its rows are
    /// backed by — the "Restore book & its pages" path of the
    /// restore dialog. Returns the number of leaves restored.
    @discardableResult
    public func restoreBookCascade(id: String) -> Int {
        let n = tryCatch(into: &errorMessage) { try api?.restoreBookCascade(id: id) ?? 0 } ?? 0
        load()
        return Int(n)
    }

    /// Soft-deletes a book by id and reloads.
    public func deleteBook(id: String) {
        if tryCatch(into: &errorMessage, { try api?.deleteBook(id: id) }) != nil {
            load()
        }
    }

    /// Returns leaves whose title matches `query` (case-insensitive).
    public func search(query: String) -> [LeafMetaFfi] {
        guard !query.isEmpty, let api else { return [] }
        return (try? api.searchLeaves(query: query)) ?? []
    }

    /// Runs all available search axes in a single FFI call : titles + block
    /// content for leaves, plus book titles and shelf names. The
    /// leaf-axis deduplication (a doc matching both title and content
    /// shows up once, in the title hits) happens on the Rust side.
    public func superSearch(query: String) -> SuperSearchResults {
        guard !query.isEmpty, let api else { return .empty }
        guard let results = try? api.superSearch(query: query) else { return .empty }
        return SuperSearchResults(
            leavesByTitle: results.leavesByTitle,
            leavesByContent: results.leavesByContent,
            books: results.books,
            shelves: results.shelves
        )
    }

    /// Bundle of search results across every library surface. Empty
    /// arrays mean "no match in that category" — callers use the per-
    /// section count to decide whether to render the section.
    public struct SuperSearchResults: Sendable {
        public let leavesByTitle: [LeafMetaFfi]
        public let leavesByContent: [BlockSearchHitFfi]
        public let books: [BookMetaFfi]
        public let shelves: [ShelfMetaFfi]

        public var isEmpty: Bool {
            leavesByTitle.isEmpty
                && leavesByContent.isEmpty
                && books.isEmpty
                && shelves.isEmpty
        }

        public static let empty = SuperSearchResults(
            leavesByTitle: [],
            leavesByContent: [],
            books: [],
            shelves: []
        )
    }

    // ── Shelves ───────────────────────────────────────────────────────────────

    /// Returns the cached shelves array. Reads from the `@Observable`
    /// `shelves` property so SwiftUI views that call this re-evaluate
    /// when `load()` refreshes the cache after a move/rename/delete.
    public func listShelves() -> [ShelfMetaFfi] {
        shelves
    }

    /// Creates a shelf and reloads.
    @discardableResult
    public func createShelf(name: String, parentId: String? = nil) -> ShelfMetaFfi? {
        guard let api else { return nil }
        let shelf = tryCatch(into: &errorMessage) { try api.createShelf(name: name, parentId: parentId) }
        return shelf
    }

    /// Renames a shelf and reloads.
    public func renameShelf(id: String, newName: String) {
        tryCatch(into: &errorMessage) { try api?.renameShelf(id: id, newName: newName) }
        load()
    }

    /// Sets or clears a shelf's emoji icon and reloads.
    public func updateShelfIcon(id: String, icon: String?) {
        tryCatch(into: &errorMessage) { try api?.updateShelfIcon(id: id, icon: icon) }
        load()
    }

    /// Deletes a shelf (orphaned docs move to root) and reloads.
    public func deleteShelf(id: String) {
        tryCatch(into: &errorMessage) { try api?.deleteShelf(id: id) }
        load()
    }

    /// Cascade delete : trashes the shelf with every leaf filed
    /// inside it AND every sub-shelf recursively. Returns the count
    /// of leaves trashed alongside so the caller can surface a
    /// confirmation toast.
    @discardableResult
    public func deleteShelfCascade(id: String) -> UInt32 {
        var deleted: UInt32 = 0
        tryCatch(into: &errorMessage) {
            deleted = try api?.deleteShelfCascade(id: id) ?? 0
        }
        load()
        return deleted
    }

    /// Moves a leaf into a shelf (or to root when `shelfId` is nil) and reloads.
    public func moveLeafToShelf(leafId: String, shelfId: String?) {
        tryCatch(into: &errorMessage) { try api?.moveLeafToShelf(leafId: leafId, shelfId: shelfId) }
        load()
    }

    /// Moves a shelf under another shelf (or to root when `newParentId` is nil)
    /// and reloads. Used by the shelf-in-shelf UI.
    public func moveShelf(id: String, newParentId: String?) {
        tryCatch(into: &errorMessage) { try api?.moveShelfTo(id: id, newParentId: newParentId) }
        load()
    }

    /// Returns the direct children of `parentId` (`nil` = root-level shelves).
    /// Filters the cached `shelves` array so SwiftUI tracks the read
    /// and re-evaluates views when `load()` refreshes the cache —
    /// fixes the "shelf doesn't disappear from root after Move to…"
    /// re-render bug we hit with the previous direct-FFI accessor.
    public func childShelves(of parentId: String?) -> [ShelfMetaFfi] {
        shelves.filter { $0.parentId == parentId }
    }

    /// Returns leaves in the given shelf (`nil` = root level). Filters
    /// the cached `allLeaves` array so SwiftUI tracks the read and
    /// re-evaluates views when `load()` refreshes the cache — same
    /// fix as `childShelves(of:)`.
    public func documentsInShelf(shelfId: String?) -> [LeafMetaFfi] {
        allLeaves.filter { $0.shelfId == shelfId && ($0.parentLeafId ?? "").isEmpty }
    }

    // ── Trash (soft-deleted items) ────────────────────────────────────────────

    /// Returns the trashed leaves (newest-deleted first).
    public func listDeletedLeaves() -> [LeafMetaFfi] {
        guard let api else { return [] }
        return (try? api.listDeletedLeaves()) ?? []
    }

    /// Returns the trashed books.
    public func listDeletedBooks() -> [BookMetaFfi] {
        guard let api else { return [] }
        return (try? api.listDeletedBooks()) ?? []
    }

    /// Returns the trashed shelves.
    public func listDeletedShelves() -> [ShelfMetaFfi] {
        guard let api else { return [] }
        return (try? api.listDeletedShelves()) ?? []
    }

    /// Restores a soft-deleted leaf.
    public func restoreLeaf(id: String) {
        tryCatch(into: &errorMessage) { try api?.restoreLeaf(id: id) }
        load()
    }

    /// Permanently deletes a soft-deleted leaf.
    public func purgeLeaf(id: String) {
        tryCatch(into: &errorMessage) { try api?.purgeLeaf(id: id) }
    }

    /// Restores a soft-deleted book.
    public func restoreBook(id: String) {
        tryCatch(into: &errorMessage) { try api?.restoreBook(id: id) }
        load()
    }

    /// Permanently deletes a soft-deleted book.
    public func purgeBook(id: String) {
        tryCatch(into: &errorMessage) { try api?.purgeBook(id: id) }
    }

    /// Restores a soft-deleted shelf.
    public func restoreShelf(id: String) {
        tryCatch(into: &errorMessage) { try api?.restoreShelf(id: id) }
        load()
    }

    /// Permanently deletes a soft-deleted shelf.
    public func purgeShelf(id: String) {
        tryCatch(into: &errorMessage) { try api?.purgeShelf(id: id) }
    }

    /// Empties the trash by purging every soft-deleted leaf, book
    /// and shelf in a single bulk FFI call. Returns the total number of
    /// items removed.
    @discardableResult
    public func emptyTrash() -> Int {
        let purged = tryCatch(into: &errorMessage) { try api?.emptyTrash() ?? 0 } ?? 0
        load()
        return Int(purged)
    }
}
