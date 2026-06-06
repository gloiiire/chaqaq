import SwiftUI

// ── Store ─────────────────────────────────────────────────────────────────────

/// A unified workspace item — either a note or a database.
enum WorkspaceItem: Identifiable {
    case note(DocumentMetaFfi)
    case database(DatabaseMetaFfi)

    var id: String {
        switch self { case .note(let d): return d.id; case .database(let db): return db.id }
    }
    var titlePlain: String {
        switch self { case .note(let d): return d.titlePlain; case .database(let db): return db.titlePlain }
    }
    var updatedAt: String {
        switch self { case .note(let d): return d.updatedAt; case .database(let db): return db.updatedAt }
    }
    var isDatabase: Bool { if case .database = self { return true }; return false }
}

/// Observable store that owns the `PinkhaApi` connection and the full workspace (notes + databases).
@MainActor
final class PinkhaStore: ObservableObject {
    @Published var documents: [DocumentMetaFfi] = []
    @Published var databases: [DatabaseMetaFfi] = []
    @Published var errorMessage: String?
    /// `true` when the Inbox tab has at least one item awaiting the user's
    /// attention — flips the tab icon to `tray.badge.fill`. Wired manually
    /// for now (no real notification source yet); future imports / shared
    /// items / sync events can flip this.
    @Published var hasInboxNotification: Bool = false

    private(set) var api: PinkhaApi?

    /// All workspace items merged and sorted by most recently updated.
    var items: [WorkspaceItem] {
        let notes = documents.map { WorkspaceItem.note($0) }
        let dbs   = databases.map { WorkspaceItem.database($0) }
        return (notes + dbs).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The N most recently updated items for the recent strip,
    /// where N is the user's `AppSettings.recentCount` (default 7,
    /// bounded 5–20). Caller supplies the count so PinkhaStore stays
    /// independent of `AppSettings`.
    func recentItems(limit: Int) -> [WorkspaceItem] {
        Array(items.prefix(limit))
    }

    /// Opens the SQLite database and seeds it when running under UI-test launch arguments.
    func connect() {
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
    func load() {
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
    func childDocuments(of parentDocId: String) -> [DocumentMetaFfi] {
        guard let api else { return [] }
        return (try? api.listChildDocuments(parentDocId: parentDocId)) ?? []
    }

    /// Moves a document under another parent document, or to root when
    /// `newParentDocId` is `nil`.
    func moveDocumentToParent(docId: String, newParentDocId: String?) {
        tryCatch(into: &errorMessage) {
            try api?.updateDocumentParent(docId: docId, newParentDocId: newParentDocId)
        }
        load()
    }

    /// Creates a new note and reloads.
    func create(title: String) {
        createNote(title: title, in: .root)
    }

    /// Creates a new database and reloads.
    func createDatabase(title: String) {
        createDatabase(title: title, in: .root)
    }

    /// Context-aware note creation. Lands the new document in `context`
    /// after creation — moved into a folder, parented under another
    /// document, or left at the root. Returns the new document id so
    /// callers can chain follow-up work (e.g. signalling a Page block
    /// insertion to the active editor's view-model for `.document`
    /// context — done by the bubble's sheet handler, *not* here, to
    /// avoid racing with the editor's in-memory blocks array).
    @discardableResult
    func createNote(title: String, in context: Composer.CreationContext) -> String? {
        guard let api else { return nil }
        do {
            let docId = try api.createDocument(title: title)
            switch context {
            case .root:
                break
            case .folder(let folderId):
                try api.moveDocumentToFolder(docId: docId, folderId: folderId)
            case .document(let parentDocId):
                try api.updateDocumentParent(docId: docId, newParentDocId: parentDocId)
            }
            load()
            return docId
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Context-aware database creation. In `.document` context the new
    /// database is embedded in the parent doc via a `Database` block so
    /// it shows up inline. Folders aren't supported on databases yet —
    /// the database lands at the workspace root in that case.
    func createDatabase(title: String, in context: Composer.CreationContext) {
        guard let api else { return }
        do {
            let dbId = try api.createDatabase(title: title)
            if case .document(let parentDocId) = context {
                let dbBlock = BlockContentFfi.database(id: dbId)
                if let json = try? JSONEncoder().encode(dbBlock),
                   let payload = String(data: json, encoding: .utf8) {
                    _ = try? api.addBlock(docId: parentDocId, blockContentJson: payload)
                }
            }
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Context-aware folder creation. Honours folder nesting (parent
    /// folder = current folder); falls back to the root in `.document`
    /// context (folders can't live inside a document).
    func createFolder(name: String, in context: Composer.CreationContext) {
        let parentId: String?
        switch context {
        case .root, .document:    parentId = nil
        case .folder(let id):     parentId = id
        }
        _ = createFolder(name: name, parentId: parentId)
        load()
    }

    /// Renames a note (updates its title) and reloads so the home
    /// list reflects the new value.
    func renameDocument(id: String, newTitle: String) {
        if tryCatch(into: &errorMessage, {
            try api?.updateDocumentTitle(id: id, newTitle: newTitle)
        }) != nil {
            load()
        }
    }

    /// Soft-deletes a note by id and reloads.
    func delete(id: String) {
        if tryCatch(into: &errorMessage, { try api?.deleteDocument(id: id) }) != nil {
            load()
        }
    }

    /// Soft-deletes all documents and reloads.
    func deleteAll() {
        if tryCatch(into: &errorMessage, { try api?.deleteAllDocuments() }) != nil {
            load()
        }
    }

    /// Soft-deletes all databases and reloads.
    func deleteAllDatabases() {
        if tryCatch(into: &errorMessage, { try api?.deleteAllDatabases() }) != nil {
            load()
        }
    }

    /// Soft-deletes all folders (orphan contents fall back to root).
    /// Used by the "Delete all" flow so a clean wipe includes folders.
    func deleteAllFolders() {
        if tryCatch(into: &errorMessage, { try api?.deleteAllFolders() }) != nil {
            load()
        }
    }

    /// Soft-deletes a database by id and reloads.
    func deleteDatabase(id: String) {
        if tryCatch(into: &errorMessage, { try api?.deleteDatabase(id: id) }) != nil {
            load()
        }
    }

    /// Returns notes whose title matches `query` (case-insensitive).
    func search(query: String) -> [DocumentMetaFfi] {
        guard !query.isEmpty, let api else { return [] }
        return (try? api.searchDocuments(query: query)) ?? []
    }

    /// Runs all available search axes in a single call : titles + block
    /// content for documents, plus database titles and folder names. The
    /// document axis is deduplicated — a doc matching both title and
    /// content shows up once in the title hits and is hidden from the
    /// content hits.
    func superSearch(query: String) -> SuperSearchResults {
        guard !query.isEmpty, let api else { return .empty }
        let titles = (try? api.searchDocuments(query: query)) ?? []
        // Use the snippets variant so the UI can show a Notion-style
        // preview of where the match landed in the doc's content.
        let blockHits = (try? api.searchInBlocksWithSnippets(query: query)) ?? []
        let dbs = (try? api.searchDatabases(query: query)) ?? []
        let folders = (try? api.searchFolders(query: query)) ?? []
        // A doc matching by title shows up in the title section once;
        // its block-level hits are still kept so the user can jump to a
        // specific occurrence inside the body — multiple snippet rows
        // per doc are intentional now that the Rust side returns every
        // matching block, not just the first one.
        let titleIds = Set(titles.map(\.id))
        let contentOnly = blockHits.filter { !titleIds.contains($0.doc.id) }
        return SuperSearchResults(
            documentsByTitle: titles,
            documentsByContent: contentOnly,
            databases: dbs,
            folders: folders
        )
    }

    /// Bundle of search results across every workspace surface. Empty
    /// arrays mean "no match in that category" — callers use the per-
    /// section count to decide whether to render the section.
    struct SuperSearchResults {
        let documentsByTitle: [DocumentMetaFfi]
        let documentsByContent: [BlockSearchHitFfi]
        let databases: [DatabaseMetaFfi]
        let folders: [FolderMetaFfi]

        var isEmpty: Bool {
            documentsByTitle.isEmpty
                && documentsByContent.isEmpty
                && databases.isEmpty
                && folders.isEmpty
        }

        static let empty = SuperSearchResults(
            documentsByTitle: [],
            documentsByContent: [],
            databases: [],
            folders: []
        )
    }

    // ── Folders ───────────────────────────────────────────────────────────────

    /// Returns all folders sorted by name.
    func listFolders() -> [FolderMetaFfi] {
        guard let api else { return [] }
        return (try? api.listFolders()) ?? []
    }

    /// Creates a folder and reloads.
    @discardableResult
    func createFolder(name: String, parentId: String? = nil) -> FolderMetaFfi? {
        guard let api else { return nil }
        let folder = tryCatch(into: &errorMessage) { try api.createFolder(name: name, parentId: parentId) }
        return folder
    }

    /// Renames a folder and reloads.
    func renameFolder(id: String, newName: String) {
        tryCatch(into: &errorMessage) { try api?.renameFolder(id: id, newName: newName) }
        load()
    }

    /// Sets or clears a folder's emoji icon and reloads.
    func updateFolderIcon(id: String, icon: String?) {
        tryCatch(into: &errorMessage) { try api?.updateFolderIcon(id: id, icon: icon) }
        load()
    }

    /// Deletes a folder (orphaned docs move to root) and reloads.
    func deleteFolder(id: String) {
        tryCatch(into: &errorMessage) { try api?.deleteFolder(id: id) }
        load()
    }

    /// Moves a document into a folder (or to root when `folderId` is nil) and reloads.
    func moveDocumentToFolder(docId: String, folderId: String?) {
        tryCatch(into: &errorMessage) { try api?.moveDocumentToFolder(docId: docId, folderId: folderId) }
        load()
    }

    /// Moves a folder under another folder (or to root when `newParentId` is nil)
    /// and reloads. Used by the folder-in-folder UI.
    func moveFolder(id: String, newParentId: String?) {
        tryCatch(into: &errorMessage) { try api?.moveFolderTo(id: id, newParentId: newParentId) }
        load()
    }

    /// Returns the direct children of `parentId` (`nil` = root-level folders).
    func childFolders(of parentId: String?) -> [FolderMetaFfi] {
        listFolders().filter { $0.parentId == parentId }
    }

    /// Returns documents in the given folder (`nil` = root level).
    func documentsInFolder(folderId: String?) -> [DocumentMetaFfi] {
        guard let api else { return [] }
        return (try? api.listDocumentsInFolder(folderId: folderId)) ?? []
    }

    // ── Trash (soft-deleted items) ────────────────────────────────────────────

    /// Returns the trashed documents (newest-deleted first).
    func listDeletedDocuments() -> [DocumentMetaFfi] {
        guard let api else { return [] }
        return (try? api.listDeletedDocuments()) ?? []
    }

    /// Returns the trashed databases.
    func listDeletedDatabases() -> [DatabaseMetaFfi] {
        guard let api else { return [] }
        return (try? api.listDeletedDatabases()) ?? []
    }

    /// Returns the trashed folders.
    func listDeletedFolders() -> [FolderMetaFfi] {
        guard let api else { return [] }
        return (try? api.listDeletedFolders()) ?? []
    }

    /// Restores a soft-deleted document.
    func restoreDocument(id: String) {
        tryCatch(into: &errorMessage) { try api?.restoreDocument(id: id) }
        load()
    }

    /// Permanently deletes a soft-deleted document.
    func purgeDocument(id: String) {
        tryCatch(into: &errorMessage) { try api?.purgeDocument(id: id) }
    }

    /// Restores a soft-deleted database.
    func restoreDatabase(id: String) {
        tryCatch(into: &errorMessage) { try api?.restoreDatabase(id: id) }
        load()
    }

    /// Permanently deletes a soft-deleted database.
    func purgeDatabase(id: String) {
        tryCatch(into: &errorMessage) { try api?.purgeDatabase(id: id) }
    }

    /// Restores a soft-deleted folder.
    func restoreFolder(id: String) {
        tryCatch(into: &errorMessage) { try api?.restoreFolder(id: id) }
        load()
    }

    /// Permanently deletes a soft-deleted folder.
    func purgeFolder(id: String) {
        tryCatch(into: &errorMessage) { try api?.purgeFolder(id: id) }
    }

    /// Empties the trash by purging every soft-deleted document, database
    /// and folder. Returns the total number of items removed.
    @discardableResult
    func emptyTrash() -> Int {
        let docs = listDeletedDocuments()
        let dbs = listDeletedDatabases()
        let folders = listDeletedFolders()
        for d in docs { purgeDocument(id: d.id) }
        for d in dbs { purgeDatabase(id: d.id) }
        for f in folders { purgeFolder(id: f.id) }
        load()
        return docs.count + dbs.count + folders.count
    }
}
