import Testing
import Foundation
import PinkhaFFI
@testable import BookFeature
@testable import Pinkha

@Suite("Leaf operations — edge cases")
struct EdgeOpsTests {

    private func makeApi() throws -> (PinkhaApi, URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_edgeops_\(UUID().uuidString).db")
        let api = try PinkhaApi(dbPath: tmp.path)
        let leafId = try api.createLeaf(title: "Edge")
        return (api, tmp, leafId)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    private func textJson(_ s: String) throws -> String {
        let c = BlockContentFfi.text([InlineTextFfi(content: s, styles: [])])
        return try String(data: JSONEncoder().encode(c), encoding: .utf8)!
    }

    @Test func updateLeafTitleToEmpty() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        try api.updateLeafTitle(id: leafId, newTitle: "")
        let metas = try api.listLeaves()
        #expect(metas.first?.titlePlain == "")
    }

    @Test func addDeleteThenReaddBlockSucceeds() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        let json = try textJson("A")
        let id1 = try api.addBlock(leafId: leafId, blockContentJson: json)
        try api.deleteBlock(leafId: leafId, blockId: id1)
        let id2 = try api.addBlock(leafId: leafId, blockContentJson: json)
        #expect(id1 != id2, "le nouveau bloc doit avoir un UUID distinct")
    }

    @Test func reorderWithMissingIdsIgnoresThem() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        let json = try textJson("A")
        let a = try api.addBlock(leafId: leafId, blockContentJson: json)
        let b = try api.addBlock(leafId: leafId, blockContentJson: json)
        let fakeId = UUID().uuidString
        // The order contains an unknown UUID — it must be ignored, b and a reordered.
        try api.reorderBlocks(leafId: leafId, order: [fakeId, b, a])
        let doc = try JSONDecoder().decode(
            LeafFfi.self,
            from: try api.getLeafJson(id: leafId).data(using: .utf8)!
        )
        #expect(doc.blocks.map(\.id) == [b, a])
    }

    @Test func reorderWithPartialOrderKeepsRest() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        let json = try textJson("A")
        let a = try api.addBlock(leafId: leafId, blockContentJson: json)
        let b = try api.addBlock(leafId: leafId, blockContentJson: json)
        let c = try api.addBlock(leafId: leafId, blockContentJson: json)
        // Only mentions c, a → b must be kept at the end.
        try api.reorderBlocks(leafId: leafId, order: [c, a])
        let doc = try JSONDecoder().decode(
            LeafFfi.self,
            from: try api.getLeafJson(id: leafId).data(using: .utf8)!
        )
        #expect(doc.blocks.map(\.id) == [c, a, b])
    }

    @Test func deleteAlreadyDeletedThrowsNotFound() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        let id = try api.addBlock(leafId: leafId, blockContentJson: try textJson("x"))
        try api.deleteBlock(leafId: leafId, blockId: id)
        #expect(throws: PinkhaError.self) {
            try api.deleteBlock(leafId: leafId, blockId: id)
        }
    }

    @Test func searchWithSpecialCharactersDoesNotCrash() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        _ = try api.addBlock(leafId: leafId, blockContentJson: try textJson("contenu normal"))
        // Special characters in the query: must not crash.
        _ = try api.searchInBlocks(query: "%_'\\\"")
        _ = try api.searchInBlocks(query: "🎯")
    }
}
