import SwiftUI
import PinkhaFFI

// ── Store ─────────────────────────────────────────────────────────────────────

// `WorkspaceItem` moved to PinkhaCore (Phase 4A) so the UIKit bridge
// targets can reference it without depending on the app target. Same
// shape as before, only the home module changes.

/// Observable store that owns the `PinkhaApi` connection and the full workspace (notes + databases).
@MainActor
@Observable
public final class PinkhaStore {
    public var documents: [DocumentMetaFfi] = []
    public var databases: [DatabaseMetaFfi] = []
    public var errorMessage: String?
    /// `true` when the Inbox tab has at least one item awaiting the user's
    /// attention — flips the tab icon to `tray.badge.fill`. Wired manually
    /// for now (no real notification source yet); future imports / shared
    /// items / sync events can flip this.
    public var hasInboxNotification: Bool = false

    @ObservationIgnored public private(set) var api: PinkhaApi?

    public init() {}

    /// All workspace items merged and sorted by most recently updated.
    public var items: [WorkspaceItem] {
        let notes = documents.map { WorkspaceItem.note($0) }
        let dbs   = databases.map { WorkspaceItem.database($0) }
        return (notes + dbs).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The N most recently updated items for the recent strip,
    /// where N is the user's `AppSettings.recentCount` (default 7,
    /// bounded 5–20). Caller supplies the count so PinkhaStore stays
    /// independent of `AppSettings`.
    public func recentItems(limit: Int) -> [WorkspaceItem] {
        Array(items.prefix(limit))
    }

    /// Opens the SQLite database and seeds it when running under UI-test launch arguments.
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
                _ = try api?.createDocument(title: "Seeded Note 1")
                _ = try api?.createDocument(title: "Seeded Note 2")
            }
            // --ui-test-clean: empty ephemeral DB, ideal for testing the empty state.
        }
        if api != nil { load() }
    }

    /// Refreshes documents and databases from the SQLite store.
    /// Only root pages (no `parentDocId`) are surfaced — child pages are
    /// reached by tapping their parent's inline `Page` block.
    public func load() {
        if let docs = tryCatch(into: &errorMessage, { try api?.listRootDocuments() ?? [] }) {
            documents = docs
        }
        if let dbs = tryCatch(into: &errorMessage, { try api?.listDatabases() ?? [] }) {
            databases = dbs
        }
    }

    /// Direct child pages of a given parent document. Used by the document
    /// view to surface sub-pages even when they aren't placed inline as
    /// `BlockContent::Page` blocks yet.
    public func childDocuments(of parentDocId: String) -> [DocumentMetaFfi] {
        guard let api else { return [] }
        return (try? api.listChildDocuments(parentDocId: parentDocId)) ?? []
    }

    /// Moves a document under another parent document, or to root when
    /// `newParentDocId` is `nil`.
    public func moveDocumentToParent(docId: String, newParentDocId: String?) {
        tryCatch(into: &errorMessage) {
            try api?.updateDocumentParent(docId: docId, newParentDocId: newParentDocId)
        }
        load()
    }

    /// Creates a new note at the workspace root and reloads.
    /// Context-aware overloads (folder / inside a doc / with a
    /// `StandaloneStyle`) live in `PinkhaStore+Composer.swift` in the
    /// Notes layer so PinkhaCore stays independent of the
    /// feature-layer `Composer.CreationContext` and
    /// `CreateDocumentSheet.StandaloneStyle` types.
    public func create(title: String) {
        guard let api else { return }
        tryCatch(into: &errorMessage) {
            _ = try api.createDocument(title: title)
        }
        load()
    }

    /// Creates a new database at the workspace root and reloads. See
    /// `create(title:)` for the rationale; the context-aware overload
    /// lives in the Notes-layer extension.
    public func createDatabase(title: String) {
        guard let api else { return }
        tryCatch(into: &errorMessage) {
            _ = try api.createDatabase(title: title)
        }
        load()
    }

    /// Renames a note (updates its title) and reloads so the home
    /// list reflects the new value.
    public func renameDocument(id: String, newTitle: String) {
        if tryCatch(into: &errorMessage, {
            try api?.updateDocumentTitle(id: id, newTitle: newTitle)
        }) != nil {
            load()
        }
    }

    /// Soft-deletes a note by id and reloads.
    public func delete(id: String) {
        if tryCatch(into: &errorMessage, { try api?.deleteDocument(id: id) }) != nil {
            load()
        }
    }

    /// Soft-deletes all documents and reloads.
    public func deleteAll() {
        if tryCatch(into: &errorMessage, { try api?.deleteAllDocuments() }) != nil {
            load()
        }
    }

    /// Soft-deletes all databases and reloads.
    public func deleteAllDatabases() {
        if tryCatch(into: &errorMessage, { try api?.deleteAllDatabases() }) != nil {
            load()
        }
    }

    /// Soft-deletes all folders (orphan contents fall back to root).
    /// Used by the "Delete all" flow so a clean wipe includes folders.
    public func deleteAllFolders() {
        if tryCatch(into: &errorMessage, { try api?.deleteAllFolders() }) != nil {
            load()
        }
    }

    /// Soft-deletes a database AND every document its rows are backed
    /// by — the "Delete database & its pages" path of the delete dialog.
    /// Returns the number of documents trashed alongside the database.
    @discardableResult
    public func deleteDatabaseCascade(id: String) -> Int {
        let n = tryCatch(into: &errorMessage) { try api?.deleteDatabaseCascade(id: id) ?? 0 } ?? 0
        load()
        return Int(n)
    }

    /// Restores a soft-deleted database AND every document its rows are
    /// backed by — the "Restore database & its pages" path of the
    /// restore dialog. Returns the number of documents restored.
    @discardableResult
    public func restoreDatabaseCascade(id: String) -> Int {
        let n = tryCatch(into: &errorMessage) { try api?.restoreDatabaseCascade(id: id) ?? 0 } ?? 0
        load()
        return Int(n)
    }

    /// Soft-deletes a database by id and reloads.
    public func deleteDatabase(id: String) {
        if tryCatch(into: &errorMessage, { try api?.deleteDatabase(id: id) }) != nil {
            load()
        }
    }

    /// Returns notes whose title matches `query` (case-insensitive).
    public func search(query: String) -> [DocumentMetaFfi] {
        guard !query.isEmpty, let api else { return [] }
        return (try? api.searchDocuments(query: query)) ?? []
    }

    /// Runs all available search axes in a single FFI call : titles + block
    /// content for documents, plus database titles and folder names. The
    /// document-axis deduplication (a doc matching both title and content
    /// shows up once, in the title hits) happens on the Rust side.
    public func superSearch(query: String) -> SuperSearchResults {
        guard !query.isEmpty, let api else { return .empty }
        guard let results = try? api.superSearch(query: query) else { return .empty }
        return SuperSearchResults(
            documentsByTitle: results.documentsByTitle,
            documentsByContent: results.documentsByContent,
            databases: results.databases,
            folders: results.folders
        )
    }

    /// Bundle of search results across every workspace surface. Empty
    /// arrays mean "no match in that category" — callers use the per-
    /// section count to decide whether to render the section.
    public struct SuperSearchResults: Sendable {
        public let documentsByTitle: [DocumentMetaFfi]
        public let documentsByContent: [BlockSearchHitFfi]
        public let databases: [DatabaseMetaFfi]
        public let folders: [FolderMetaFfi]

        public var isEmpty: Bool {
            documentsByTitle.isEmpty
                && documentsByContent.isEmpty
                && databases.isEmpty
                && folders.isEmpty
        }

        public static let empty = SuperSearchResults(
            documentsByTitle: [],
            documentsByContent: [],
            databases: [],
            folders: []
        )
    }

    // ── Folders ───────────────────────────────────────────────────────────────

    /// Returns all folders sorted by name.
    public func listFolders() -> [FolderMetaFfi] {
        guard let api else { return [] }
        return (try? api.listFolders()) ?? []
    }

    /// Creates a folder and reloads.
    @discardableResult
    public func createFolder(name: String, parentId: String? = nil) -> FolderMetaFfi? {
        guard let api else { return nil }
        let folder = tryCatch(into: &errorMessage) { try api.createFolder(name: name, parentId: parentId) }
        return folder
    }

    /// Renames a folder and reloads.
    public func renameFolder(id: String, newName: String) {
        tryCatch(into: &errorMessage) { try api?.renameFolder(id: id, newName: newName) }
        load()
    }

    /// Sets or clears a folder's emoji icon and reloads.
    public func updateFolderIcon(id: String, icon: String?) {
        tryCatch(into: &errorMessage) { try api?.updateFolderIcon(id: id, icon: icon) }
        load()
    }

    /// Deletes a folder (orphaned docs move to root) and reloads.
    public func deleteFolder(id: String) {
        tryCatch(into: &errorMessage) { try api?.deleteFolder(id: id) }
        load()
    }

    /// Moves a document into a folder (or to root when `folderId` is nil) and reloads.
    public func moveDocumentToFolder(docId: String, folderId: String?) {
        tryCatch(into: &errorMessage) { try api?.moveDocumentToFolder(docId: docId, folderId: folderId) }
        load()
    }

    /// Moves a folder under another folder (or to root when `newParentId` is nil)
    /// and reloads. Used by the folder-in-folder UI.
    public func moveFolder(id: String, newParentId: String?) {
        tryCatch(into: &errorMessage) { try api?.moveFolderTo(id: id, newParentId: newParentId) }
        load()
    }

    /// Returns the direct children of `parentId` (`nil` = root-level folders).
    /// The parent/child filtering runs in Rust.
    public func childFolders(of parentId: String?) -> [FolderMetaFfi] {
        guard let api else { return [] }
        return (try? api.listChildFolders(parentId: parentId)) ?? []
    }

    /// Returns documents in the given folder (`nil` = root level).
    public func documentsInFolder(folderId: String?) -> [DocumentMetaFfi] {
        guard let api else { return [] }
        return (try? api.listDocumentsInFolder(folderId: folderId)) ?? []
    }

    // ── Trash (soft-deleted items) ────────────────────────────────────────────

    /// Returns the trashed documents (newest-deleted first).
    public func listDeletedDocuments() -> [DocumentMetaFfi] {
        guard let api else { return [] }
        return (try? api.listDeletedDocuments()) ?? []
    }

    /// Returns the trashed databases.
    public func listDeletedDatabases() -> [DatabaseMetaFfi] {
        guard let api else { return [] }
        return (try? api.listDeletedDatabases()) ?? []
    }

    /// Returns the trashed folders.
    public func listDeletedFolders() -> [FolderMetaFfi] {
        guard let api else { return [] }
        return (try? api.listDeletedFolders()) ?? []
    }

    /// Restores a soft-deleted document.
    public func restoreDocument(id: String) {
        tryCatch(into: &errorMessage) { try api?.restoreDocument(id: id) }
        load()
    }

    /// Permanently deletes a soft-deleted document.
    public func purgeDocument(id: String) {
        tryCatch(into: &errorMessage) { try api?.purgeDocument(id: id) }
    }

    /// Restores a soft-deleted database.
    public func restoreDatabase(id: String) {
        tryCatch(into: &errorMessage) { try api?.restoreDatabase(id: id) }
        load()
    }

    /// Permanently deletes a soft-deleted database.
    public func purgeDatabase(id: String) {
        tryCatch(into: &errorMessage) { try api?.purgeDatabase(id: id) }
    }

    /// Restores a soft-deleted folder.
    public func restoreFolder(id: String) {
        tryCatch(into: &errorMessage) { try api?.restoreFolder(id: id) }
        load()
    }

    /// Permanently deletes a soft-deleted folder.
    public func purgeFolder(id: String) {
        tryCatch(into: &errorMessage) { try api?.purgeFolder(id: id) }
    }

    /// Empties the trash by purging every soft-deleted document, database
    /// and folder in a single bulk FFI call. Returns the total number of
    /// items removed.
    @discardableResult
    public func emptyTrash() -> Int {
        let purged = tryCatch(into: &errorMessage) { try api?.emptyTrash() ?? 0 } ?? 0
        load()
        return Int(purged)
    }
}
