import Testing
import Foundation
import PinkhaFFI
@testable import BookFeature
@testable import Pinkha

// Persistence: content must survive app close and reopen
// (verifies that SQLite + WAL flush correctly).

@Suite("Persistence — survives reopen")
struct PersistenceTests {

    @Test func documentSurvivesReopen() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_persist_\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("shm"))
        }

        let leafId: String
        do {
            let api = try PinkhaApi(dbPath: tmp.path)
            leafId = try api.createLeaf(title: "Persistent")
            try api.updateLeafTitle(id: leafId, newTitle: "Modified")
        }
        // New API instance on the same file.
        let api2 = try PinkhaApi(dbPath: tmp.path)
        let metas = try api2.listLeaves()
        #expect(metas.contains(where: { $0.id == leafId && $0.titlePlain == "Modified" }))
    }

    @Test func blocksSurviveReopen() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_persist_\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("shm"))
        }

        let leafId: String
        let blockId: String
        do {
            let api = try PinkhaApi(dbPath: tmp.path)
            leafId = try api.createLeaf(title: "Doc")
            let c = BlockContentFfi.text([InlineTextFfi(content: "Bloc", styles: [])])
            let json = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
            blockId = try api.addBlock(leafId: leafId, blockContentJson: json)
        }
        let api2 = try PinkhaApi(dbPath: tmp.path)
        let doc = try JSONDecoder().decode(
            LeafFfi.self,
            from: try api2.getLeafJson(id: leafId).data(using: .utf8)!
        )
        #expect(doc.blocks.first?.id == blockId)
        #expect(doc.blocks.first?.content.plainText == "Bloc")
    }

    @Test func softDeleteSurvivesReopen() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_persist_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let leafId: String
        do {
            let api = try PinkhaApi(dbPath: tmp.path)
            leafId = try api.createLeaf(title: "À supprimer")
            try api.deleteLeaf(id: leafId)
        }
        let api2 = try PinkhaApi(dbPath: tmp.path)
        #expect(try api2.listLeaves().isEmpty,
                "the soft-deleted leaf must not reappear after reopening")
    }
}
