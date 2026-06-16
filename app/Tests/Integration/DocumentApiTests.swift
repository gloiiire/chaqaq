import Testing
import Foundation
import PinkhaFFI
@testable import BookFeature
@testable import Pinkha

// Integration tests: Swift ↔ Rust FFI with a real PinkhaApi
// (temporary SQLite DB destroyed at the end of each test).

@Suite("PinkhaApi — leaf lifecycle")
struct LeafLifecycleTests {

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

    @Test func createLeafReturnsUuid() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let id = try api.createLeaf(title: "Hello")
        #expect(UUID(uuidString: id) != nil, "must return a valid UUID")
    }

    @Test func listLeavesAfterCreate() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        _ = try api.createLeaf(title: "A")
        _ = try api.createLeaf(title: "B")
        let metas = try api.listLeaves()
        #expect(metas.count == 2)
        #expect(metas.contains(where: { $0.titlePlain == "A" }))
        #expect(metas.contains(where: { $0.titlePlain == "B" }))
    }

    @Test func deleteLeafHidesItFromList() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let id = try api.createLeaf(title: "To delete")
        try api.deleteLeaf(id: id)
        #expect(try api.listLeaves().isEmpty)
    }

    @Test func deleteNonexistentThrowsNotFound() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let fake = UUID().uuidString
        #expect(throws: PinkhaError.self) {
            try api.deleteLeaf(id: fake)
        }
    }

    @Test func updateLeafTitlePersists() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let id = try api.createLeaf(title: "Old title")
        try api.updateLeafTitle(id: id, newTitle: "New title")
        let metas = try api.listLeaves()
        #expect(metas.first?.titlePlain == "New title")
    }

    @Test func getLeafJsonDecodesCleanly() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let id = try api.createLeaf(title: "Test")
        let json = try api.getLeafJson(id: id)
        let data = json.data(using: .utf8)!
        let doc = try JSONDecoder().decode(LeafFfi.self, from: data)
        #expect(doc.id == id)
        #expect(doc.title.map(\.content).joined() == "Test")
        #expect(doc.blocks.isEmpty)
    }
}
