import Testing
import Foundation
import PinkhaFFI
@testable import Pinkha

// Integration tests: block operations via the real PinkhaApi.

@Suite("Blocks — lifecycle via FFI")
struct BlockOpsTests {

    private func makeApi() throws -> (PinkhaApi, URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_blocks_\(UUID().uuidString).db")
        let api = try PinkhaApi(dbPath: tmp.path)
        let leafId = try api.createLeaf(title: "Test")
        return (api, tmp, leafId)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    private func textBlock(_ s: String) throws -> String {
        let content = BlockContentFfi.text([InlineTextFfi(content: s, styles: [])])
        return try String(data: JSONEncoder().encode(content), encoding: .utf8)!
    }

    @Test func addBlockReturnsUuidAndPersists() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        let blockId = try api.addBlock(leafId: leafId, blockContentJson: try textBlock("Hello"))
        #expect(UUID(uuidString: blockId) != nil)

        let json = try api.getLeafJson(id: leafId)
        let doc = try JSONDecoder().decode(LeafFfi.self, from: json.data(using: .utf8)!)
        #expect(doc.blocks.count == 1)
        #expect(doc.blocks[0].id == blockId)
        #expect(doc.blocks[0].content.plainText == "Hello")
    }

    @Test func updateBlockReplacesContent() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        let blockId = try api.addBlock(leafId: leafId, blockContentJson: try textBlock("Ancien"))
        try api.updateBlock(leafId: leafId, blockId: blockId, contentJson: try textBlock("Nouveau"))

        let json = try api.getLeafJson(id: leafId)
        let doc = try JSONDecoder().decode(LeafFfi.self, from: json.data(using: .utf8)!)
        #expect(doc.blocks[0].content.plainText == "Nouveau")
    }

    @Test func deleteBlockRemovesIt() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        let blockId = try api.addBlock(leafId: leafId, blockContentJson: try textBlock("À supprimer"))
        try api.deleteBlock(leafId: leafId, blockId: blockId)

        let json = try api.getLeafJson(id: leafId)
        let doc = try JSONDecoder().decode(LeafFfi.self, from: json.data(using: .utf8)!)
        #expect(doc.blocks.isEmpty)
    }

    @Test func reorderBlocksAppliesNewOrder() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        let a = try api.addBlock(leafId: leafId, blockContentJson: try textBlock("A"))
        let b = try api.addBlock(leafId: leafId, blockContentJson: try textBlock("B"))
        let c = try api.addBlock(leafId: leafId, blockContentJson: try textBlock("C"))

        try api.reorderBlocks(leafId: leafId, order: [c, a, b])

        let json = try api.getLeafJson(id: leafId)
        let doc = try JSONDecoder().decode(LeafFfi.self, from: json.data(using: .utf8)!)
        #expect(doc.blocks.map(\.id) == [c, a, b])
    }

    @Test func searchInBlocksFindsByContent() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        _ = try api.addBlock(leafId: leafId, blockContentJson: try textBlock("Rust is great"))

        let results = try api.searchInBlocks(query: "rust")
        #expect(results.contains(where: { $0.id == leafId }))
    }

    @Test func searchInBlocksMissesIrrelevant() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        _ = try api.addBlock(leafId: leafId, blockContentJson: try textBlock("Hello world"))

        let results = try api.searchInBlocks(query: "flutter")
        #expect(!results.contains(where: { $0.id == leafId }))
    }
}
