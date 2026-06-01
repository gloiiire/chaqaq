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

    private(set) var api: PinkhaApi?

    /// All workspace items merged and sorted by most recently updated.
    var items: [WorkspaceItem] {
        let notes = documents.map { WorkspaceItem.note($0) }
        let dbs   = databases.map { WorkspaceItem.database($0) }
        return (notes + dbs).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The 5 most recently updated items for the recent strip.
    var recentItems: [WorkspaceItem] { Array(items.prefix(5)) }

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
    func load() {
        if let docs = tryCatch(into: &errorMessage, { try api?.listDocuments() ?? [] }) {
            documents = docs
        }
        if let dbs = tryCatch(into: &errorMessage, { try api?.listDatabases() ?? [] }) {
            databases = dbs
        }
    }

    /// Creates a new note and reloads.
    func create(title: String) {
        if tryCatch(into: &errorMessage, { try api?.createDocument(title: title) }) != nil {
            load()
        }
    }

    /// Creates a new database and reloads.
    func createDatabase(title: String) {
        if tryCatch(into: &errorMessage, { try api?.createDatabase(title: title) }) != nil {
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

    /// Returns documents in the given folder (`nil` = root level).
    func documentsInFolder(folderId: String?) -> [DocumentMetaFfi] {
        guard let api else { return [] }
        return (try? api.listDocumentsInFolder(folderId: folderId)) ?? []
    }
}
