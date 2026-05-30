import Testing
import Foundation
@testable import Chaqaq

// Tests d'intégration : Swift ↔ FFI Rust avec une vraie ChaqaqApi
// (DB SQLite temporaire détruite à la fin de chaque test).

@Suite("ChaqaqApi — cycle de vie d'un document")
struct DocumentLifecycleTests {

    private func makeApi() throws -> (ChaqaqApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chaqaq_test_\(UUID().uuidString).db")
        return (try ChaqaqApi(dbPath: tmp.path), tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    @Test func createDocumentReturnsUuid() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let id = try api.createDocument(title: "Bonjour")
        #expect(UUID(uuidString: id) != nil, "doit retourner un UUID valide")
    }

    @Test func listDocumentsAfterCreate() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        _ = try api.createDocument(title: "A")
        _ = try api.createDocument(title: "B")
        let metas = try api.listDocuments()
        #expect(metas.count == 2)
        #expect(metas.contains(where: { $0.titlePlain == "A" }))
        #expect(metas.contains(where: { $0.titlePlain == "B" }))
    }

    @Test func deleteDocumentHidesItFromList() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let id = try api.createDocument(title: "À supprimer")
        try api.deleteDocument(id: id)
        #expect(try api.listDocuments().isEmpty)
    }

    @Test func deleteNonexistentThrowsNotFound() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let fake = UUID().uuidString
        #expect(throws: ChaqaqError.self) {
            try api.deleteDocument(id: fake)
        }
    }

    @Test func updateDocumentTitlePersists() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let id = try api.createDocument(title: "Ancien")
        try api.updateDocumentTitle(id: id, newTitle: "Nouveau")
        let metas = try api.listDocuments()
        #expect(metas.first?.titlePlain == "Nouveau")
    }

    @Test func getDocumentJsonDecodesCleanly() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let id = try api.createDocument(title: "Test")
        let json = try api.getDocumentJson(id: id)
        let data = json.data(using: .utf8)!
        let doc = try JSONDecoder().decode(DocumentFfi.self, from: data)
        #expect(doc.id == id)
        #expect(doc.title.map(\.content).joined() == "Test")
        #expect(doc.blocks.isEmpty)
    }
}
