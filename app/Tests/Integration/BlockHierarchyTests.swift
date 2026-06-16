import Testing
import Foundation
import PinkhaFFI
@testable import Pinkha

@Suite("Nested blocks — addChildBlock, reorderChildBlocks, moveBlock")
struct BlockHierarchyTests {

    private func makeApi() throws -> (PinkhaApi, URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_hier_\(UUID().uuidString).db")
        let api = try PinkhaApi(dbPath: tmp.path)
        let leafId = try api.createLeaf(title: "Hierarchy")
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

    @Test func addChildBlockNestsUnderParent() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        let parent = try api.addBlock(leafId: leafId, blockContentJson: try textJson("parent"))
        let child = try api.addChildBlock(
            leafId: leafId,
            parentId: parent,
            blockContentJson: try textJson("child")
        )

        let doc = try JSONDecoder().decode(
            LeafFfi.self,
            from: try api.getLeafJson(id: leafId).data(using: .utf8)!
        )
        #expect(doc.blocks.count == 1)
        #expect(doc.blocks[0].id == parent)
        #expect(doc.blocks[0].children.count == 1)
        #expect(doc.blocks[0].children[0].id == child)
    }

    @Test func reorderChildBlocksAppliesNewOrder() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        let parent = try api.addBlock(leafId: leafId, blockContentJson: try textJson("p"))
        let a = try api.addChildBlock(leafId: leafId, parentId: parent,
                                       blockContentJson: try textJson("A"))
        let b = try api.addChildBlock(leafId: leafId, parentId: parent,
                                       blockContentJson: try textJson("B"))
        let c = try api.addChildBlock(leafId: leafId, parentId: parent,
                                       blockContentJson: try textJson("C"))

        try api.reorderChildBlocks(leafId: leafId, parentId: parent, order: [c, a, b])

        let doc = try JSONDecoder().decode(
            LeafFfi.self,
            from: try api.getLeafJson(id: leafId).data(using: .utf8)!
        )
        #expect(doc.blocks[0].children.map(\.id) == [c, a, b])
    }

    @Test func moveBlockFromRootToParent() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        let parent = try api.addBlock(leafId: leafId, blockContentJson: try textJson("parent"))
        let movable = try api.addBlock(leafId: leafId, blockContentJson: try textJson("to move"))

        try api.moveBlock(leafId: leafId, blockId: movable, newParentId: parent)

        let doc = try JSONDecoder().decode(
            LeafFfi.self,
            from: try api.getLeafJson(id: leafId).data(using: .utf8)!
        )
        #expect(doc.blocks.count == 1)
        #expect(doc.blocks[0].id == parent)
        #expect(doc.blocks[0].children.count == 1)
        #expect(doc.blocks[0].children[0].id == movable)
    }

    @Test func moveBlockFromChildBackToRoot() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        let parent = try api.addBlock(leafId: leafId, blockContentJson: try textJson("p"))
        let child = try api.addChildBlock(leafId: leafId, parentId: parent,
                                           blockContentJson: try textJson("c"))

        try api.moveBlock(leafId: leafId, blockId: child, newParentId: nil)

        let doc = try JSONDecoder().decode(
            LeafFfi.self,
            from: try api.getLeafJson(id: leafId).data(using: .utf8)!
        )
        #expect(doc.blocks.count == 2)
        #expect(doc.blocks[0].children.isEmpty)
        #expect(doc.blocks[1].id == child)
    }

    @Test func moveBlockIntoItselfFails() throws {
        let (api, url, leafId) = try makeApi(); defer { cleanup(url) }
        let block = try api.addBlock(leafId: leafId, blockContentJson: try textJson("b"))
        #expect(throws: PinkhaError.self) {
            try api.moveBlock(leafId: leafId, blockId: block, newParentId: block)
        }
    }
}
