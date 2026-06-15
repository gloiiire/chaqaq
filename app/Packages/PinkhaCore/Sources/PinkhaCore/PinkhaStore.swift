import SwiftUI
import PinkhaFFI

// ── Store ─────────────────────────────────────────────────────────────────────

// `WorkspaceItem` moved to PinkhaCore (Phase 4A) so the UIKit bridge
// targets can reference it without depending on the app target. Same
// shape as before, only the home module changes.

/// Observable store that owns the `PinkhaApi` connection and the full library (notes + books).
@MainActor
@Observable
public final class PinkhaStore {
    public var leaves: [LeafMetaFfi] = []
    public var books: [BookMetaFfi] = []
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
        let notes = leaves.map { WorkspaceItem.note($0) }
        let dbs   = books.map { WorkspaceItem.book($0) }
        return (notes + dbs).sorted { $0.updatedAt > $1.updatedAt }
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
            let dir  = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            // UI-test modes: ephemeral DB for reproducibility.
            let args = ProcessInfo.processInfo.arguments
            let isUITest = args.contains("--ui-test-data") || args.contains("--ui-test-clean")
            let dbName = isUITest ? "pinkha_uitest_\(UUID().uuidString).db" : "pinkha.db"
            let path = dir.appendingPathComponent(dbName).path
            api = try PinkhaApi(dbPath: path)
            if args.contains("--ui-test-data") {
                _ = try api?.createLeaf(title: "Seeded Note 1")
                _ = try api?.createLeaf(title: "Seeded Note 2")
            }
            // --ui-test-clean: empty ephemeral DB, ideal for testing the empty state.
        }
        if api != nil { load() }
    }

    /// Refreshes leaves and books from the SQLite store.
    /// Only root pages (no `parentLeafId`) are surfaced — child pages are
    /// reached by tapping their parent's inline `Page` block.
    public func load() {
        if let docs = tryCatch(into: &errorMessage, { try api?.listRootLeaves() ?? [] }) {
            leaves = docs
        }
        if let dbs = tryCatch(into: &errorMessage, { try api?.listBooks() ?? [] }) {
            books = dbs
        }
    }

    /// Direct child pages of a given parent leaf. Used by the leaf
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

    /// Creates a new note at the library root and reloads.
    /// Context-aware overloads (shelf / inside a doc / with a
    /// `StandaloneStyle`) live in `PinkhaStore+Composer.swift` in the
    /// Notes layer so PinkhaCore stays independent of the
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
    /// lives in the Notes-layer extension.
    public func createBook(title: String) {
        guard let api else { return }
        tryCatch(into: &errorMessage) {
            _ = try api.createBook(title: title)
        }
        load()
    }

    /// Renames a note (updates its title) and reloads so the home
    /// list reflects the new value.
    public func renameLeaf(id: String, newTitle: String) {
        if tryCatch(into: &errorMessage, {
            try api?.updateLeafTitle(id: id, newTitle: newTitle)
        }) != nil {
            load()
        }
    }

    /// Soft-deletes a note by id and reloads.
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

    /// Returns notes whose title matches `query` (case-insensitive).
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

    /// Returns all shelves sorted by name.
    public func listShelves() -> [ShelfMetaFfi] {
        guard let api else { return [] }
        return (try? api.listShelves()) ?? []
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
    /// The parent/child filtering runs in Rust.
    public func childShelves(of parentId: String?) -> [ShelfMetaFfi] {
        guard let api else { return [] }
        return (try? api.listChildShelves(parentId: parentId)) ?? []
    }

    /// Returns leaves in the given shelf (`nil` = root level).
    public func documentsInShelf(shelfId: String?) -> [LeafMetaFfi] {
        guard let api else { return [] }
        return (try? api.listLeavesInShelf(shelfId: shelfId)) ?? []
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
