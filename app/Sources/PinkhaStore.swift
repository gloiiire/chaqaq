import SwiftUI

// ── Store ─────────────────────────────────────────────────────────────────────

/// Observable store qui possède la connexion `PinkhaApi` et la liste de documents.
@MainActor
final class PinkhaStore: ObservableObject {
    @Published var documents: [DocumentMetaFfi] = []
    @Published var errorMessage: String?

    private(set) var api: PinkhaApi?

    /// Ouvre la base SQLite et la seede lors de l'exécution sous arguments de lancement UI-test.
    func connect() {
        guard api == nil else { return }
        tryCatch(into: &errorMessage) {
            let dir  = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            // Modes UI-test : DB éphémère pour la reproductibilité.
            let args = ProcessInfo.processInfo.arguments
            let isUITest = args.contains("--ui-test-data") || args.contains("--ui-test-clean")
            let dbName = isUITest ? "pinkha_uitest_\(UUID().uuidString).db" : "pinkha.db"
            let path = dir.appendingPathComponent(dbName).path
            api = try PinkhaApi(dbPath: path)
            if args.contains("--ui-test-data") {
                _ = try api?.createDocument(title: "Seeded Note 1")
                _ = try api?.createDocument(title: "Seeded Note 2")
            }
            // --ui-test-clean : DB éphémère vide, idéal pour tester l'état vide.
        }
        if api != nil { load() }
    }

    /// Rafraîchit la liste de documents depuis la base de données.
    func load() {
        if let docs = tryCatch(into: &errorMessage, { try api?.listDocuments() ?? [] }) {
            documents = docs
        }
    }

    /// Crée un nouveau document et recharge la liste.
    func create(title: String) {
        if tryCatch(into: &errorMessage, { try api?.createDocument(title: title) }) != nil {
            load()
        }
    }

    /// Soft-delete un document par id et recharge la liste.
    func delete(id: String) {
        if tryCatch(into: &errorMessage, { try api?.deleteDocument(id: id) }) != nil {
            load()
        }
    }

    /// Retourne les documents dont le titre correspond à `query` (insensible à la casse).
    func search(query: String) -> [DocumentMetaFfi] {
        guard !query.isEmpty, let api else { return [] }
        return (try? api.searchDocuments(query: query)) ?? []
    }
}
