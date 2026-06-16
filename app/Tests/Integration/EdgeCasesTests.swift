import Testing
import Foundation
import PinkhaFFI
@testable import BookFeature
@testable import Pinkha

@Suite("Edge cases — special characters, emojis, size")
struct EdgeCasesTests {

    private func makeApi() throws -> (PinkhaApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_edge_\(UUID().uuidString).db")
        return (try PinkhaApi(dbPath: tmp.path), tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    @Test func emojisInTitle() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let id = try api.createLeaf(title: "🎉 Fête 🥳")
        let metas = try api.listLeaves()
        #expect(metas.first(where: { $0.id == id })?.titlePlain == "🎉 Fête 🥳")
    }

    @Test func combiningCharactersInTitle() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        // é can be encoded in NFC (1 codepoint) or NFD (e + combining accent)
        let composed = "\u{00E9}"      // precomposed é
        let decomposed = "e\u{0301}"   // e + combining accent
        let id1 = try api.createLeaf(title: composed)
        let id2 = try api.createLeaf(title: decomposed)
        let metas = try api.listLeaves()
        #expect(metas.count == 2)
        #expect(metas.contains(where: { $0.id == id1 }))
        #expect(metas.contains(where: { $0.id == id2 }))
    }

    @Test func longTitleNearLimitAccepted() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        // 32 KB — below the 64 KB limit
        let title = String(repeating: "a", count: 32 * 1024)
        let id = try api.createLeaf(title: title)
        #expect(UUID(uuidString: id) != nil)
    }

    @Test func specialCharactersInTitle() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        // Avoid [] which is interpreted as link syntax by the inline parser.
        let weird = "\"\\<>&'`{}/\\n\\t"
        let id = try api.createLeaf(title: weird)
        let metas = try api.listLeaves()
        #expect(metas.first(where: { $0.id == id })?.titlePlain == weird)
    }

    @Test func manyBlocksInLeaf() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let leafId = try api.createLeaf(title: "Stress")
        let c = BlockContentFfi.text([InlineTextFfi(content: "B", styles: [])])
        let json = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        for _ in 0..<100 {
            _ = try api.addBlock(leafId: leafId, blockContentJson: json)
        }
        let doc = try JSONDecoder().decode(
            LeafFfi.self,
            from: try api.getLeafJson(id: leafId).data(using: .utf8)!
        )
        #expect(doc.blocks.count == 100)
    }

    @Test func unicodeInBlockContent() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let leafId = try api.createLeaf(title: "Unicode")
        let c = BlockContentFfi.text([
            InlineTextFfi(content: "中文 العربية русский ñ", styles: [])
        ])
        let json = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        _ = try api.addBlock(leafId: leafId, blockContentJson: json)

        let doc = try JSONDecoder().decode(
            LeafFfi.self,
            from: try api.getLeafJson(id: leafId).data(using: .utf8)!
        )
        #expect(doc.blocks.first?.content.plainText == "中文 العربية русский ñ")
    }
}
