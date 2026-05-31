import Testing
import Foundation
@testable import Pinkha

// Integration tests: Swift ↔ Rust FFI with a real PinkhaApi
// (temporary SQLite DB destroyed at the end of each test).

@Suite("PinkhaApi — document lifecycle")
struct DocumentLifecycleTests {

    private func makeApi() throws -> (PinkhaApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_test_\(UUID().uuidString).db")
        return (try PinkhaApi(dbPath: tmp.path), tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    @Test func createDocumentReturnsUuid() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let id = try api.createDocument(title: "Hello")
        #expect(UUID(uuidString: id) != nil, "must return a valid UUID")
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
        let id = try api.createDocument(title: "To delete")
        try api.deleteDocument(id: id)
        #expect(try api.listDocuments().isEmpty)
    }

    @Test func deleteNonexistentThrowsNotFound() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let fake = UUID().uuidString
        #expect(throws: PinkhaError.self) {
            try api.deleteDocument(id: fake)
        }
    }

    @Test func updateDocumentTitlePersists() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let id = try api.createDocument(title: "Old title")
        try api.updateDocumentTitle(id: id, newTitle: "New title")
        let metas = try api.listDocuments()
        #expect(metas.first?.titlePlain == "New title")
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
