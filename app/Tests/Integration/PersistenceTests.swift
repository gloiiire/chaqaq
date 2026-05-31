import Testing
import Foundation
@testable import Pinkha

// Persistance : le contenu doit survivre à la fermeture/réouverture de l'app
// (vérifie que SQLite + WAL flushent correctement).

@Suite("Persistance — survit à la réouverture")
struct PersistenceTests {

    @Test func documentSurvivesReopen() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_persist_\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("shm"))
        }

        let docId: String
        do {
            let api = try PinkhaApi(dbPath: tmp.path)
            docId = try api.createDocument(title: "Persistant")
            try api.updateDocumentTitle(id: docId, newTitle: "Modifié")
        }
        // Nouvelle instance d'API sur le même fichier.
        let api2 = try PinkhaApi(dbPath: tmp.path)
        let metas = try api2.listDocuments()
        #expect(metas.contains(where: { $0.id == docId && $0.titlePlain == "Modifié" }))
    }

    @Test func blocksSurviveReopen() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_persist_\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("shm"))
        }

        let docId: String
        let blockId: String
        do {
            let api = try PinkhaApi(dbPath: tmp.path)
            docId = try api.createDocument(title: "Doc")
            let c = BlockContentFfi.text([InlineTextFfi(content: "Bloc", styles: [])])
            let json = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
            blockId = try api.addBlock(docId: docId, blockContentJson: json)
        }
        let api2 = try PinkhaApi(dbPath: tmp.path)
        let doc = try JSONDecoder().decode(
            DocumentFfi.self,
            from: try api2.getDocumentJson(id: docId).data(using: .utf8)!
        )
        #expect(doc.blocks.first?.id == blockId)
        #expect(doc.blocks.first?.content.plainText == "Bloc")
    }

    @Test func softDeleteSurvivesReopen() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_persist_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let docId: String
        do {
            let api = try PinkhaApi(dbPath: tmp.path)
            docId = try api.createDocument(title: "À supprimer")
            try api.deleteDocument(id: docId)
        }
        let api2 = try PinkhaApi(dbPath: tmp.path)
        #expect(try api2.listDocuments().isEmpty,
                "le document soft-deleted ne doit pas réapparaître à la réouverture")
    }
}
