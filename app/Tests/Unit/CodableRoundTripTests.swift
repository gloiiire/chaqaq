import Testing
import Foundation
@testable import Pinkha

@Suite("InlineTextFfi — round-trip JSON")
struct InlineTextFfiTests {

    @Test func plainTextEncodesContentAndEmptyStyles() throws {
        let span = InlineTextFfi(content: "Bonjour", styles: [])
        let data = try JSONEncoder().encode(span)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"content\":\"Bonjour\""))
        #expect(json.contains("\"styles\":[]"))
    }

    @Test func styledSpanRoundTrips() throws {
        let original = InlineTextFfi(content: "x", styles: [.bold, .italic, .color("bleu")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InlineTextFfi.self, from: data)
        #expect(decoded.content == original.content)
        #expect(decoded.styles.count == original.styles.count)
    }

    @Test func emptyContentIsAllowed() throws {
        let span = InlineTextFfi(content: "", styles: [.bold])
        let data = try JSONEncoder().encode(span)
        let decoded = try JSONDecoder().decode(InlineTextFfi.self, from: data)
        #expect(decoded.content.isEmpty)
        #expect(decoded.styles.count == 1)
    }
}

@Suite("DocumentFfi — full JSON round-trip")
struct DocumentFfiTests {

    @Test func emptyDocumentRoundTrips() throws {
        let id = UUID().uuidString
        let doc = DocumentFfi(id: id, cover: nil, icon: nil, title: [], blocks: [])
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(DocumentFfi.self, from: data)
        #expect(decoded.id == id)
        #expect(decoded.cover == nil)
        #expect(decoded.title.isEmpty)
        #expect(decoded.blocks.isEmpty)
    }

    @Test func documentWithCoverEncodes() throws {
        let doc = DocumentFfi(id: "x", cover: "aurora.jpg", icon: nil, title: [], blocks: [])
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(DocumentFfi.self, from: data)
        #expect(decoded.cover == "aurora.jpg")
    }

    @Test func documentWithBlocksRoundTrips() throws {
        let block = BlockFfi(
            id: "b1",
            content: .text([InlineTextFfi(content: "Hello", styles: [.bold])]),
            children: [],
            color: nil
        )
        let doc = DocumentFfi(id: "d1", cover: nil, icon: nil,
                              title: [InlineTextFfi(content: "Titre", styles: [])],
                              blocks: [block])
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(DocumentFfi.self, from: data)
        #expect(decoded.blocks.count == 1)
        #expect(decoded.blocks[0].id == "b1")
        #expect(decoded.blocks[0].content.plainText == "Hello")
    }

    @Test func nestedChildrenRoundTrip() throws {
        let child = BlockFfi(id: "c", content: .text([]), children: [], color: nil)
        let parent = BlockFfi(id: "p", content: .text([]), children: [child], color: nil)
        let doc = DocumentFfi(id: "d", cover: nil, icon: nil, title: [], blocks: [parent])
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(DocumentFfi.self, from: data)
        #expect(decoded.blocks[0].children.count == 1)
        #expect(decoded.blocks[0].children[0].id == "c")
    }

    @Test func blockColorRoundTrips() throws {
        let block = BlockFfi(
            id: "b1",
            content: .text([InlineTextFfi(content: "Coloured", styles: [])]),
            children: [],
            color: "red"
        )
        let data = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(BlockFfi.self, from: data)
        #expect(decoded.color == "red")
    }

    /// Documents serialised before `color` existed must still decode (mirrors
    /// the Rust `#[serde(default)]` guarantee on `Block.color`).
    @Test func blockDecodesLegacyJsonWithoutColor() throws {
        let legacy = #"{"id":"b1","content":"Divider","children":[]}"#
        let data = legacy.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BlockFfi.self, from: data)
        #expect(decoded.id == "b1")
        #expect(decoded.color == nil)
    }
}

@Suite("BlockContentFfi — all payload variants")
struct BlockContentPayloadTests {

    @Test func todoPayloadEncodesDoneAndText() throws {
        let block = BlockContentFfi.todo(done: true, text: [
            InlineTextFfi(content: "Tâche", styles: [])
        ])
        let data = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(BlockContentFfi.self, from: data)
        #expect(decoded.isTodoDone)
        #expect(decoded.plainText == "Tâche")
    }

    @Test func quoteWithIconPersists() throws {
        let block = BlockContentFfi.quote(icon: "💡", text: [
            InlineTextFfi(content: "Idée", styles: [])
        ])
        let data = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(BlockContentFfi.self, from: data)
        if case .quote(let icon, let text) = decoded {
            #expect(icon == "💡")
            #expect(text.first?.content == "Idée")
        } else {
            Issue.record("expected .quote")
        }
    }

    @Test func headingLevelOneTwoThreeAllRoundTrip() throws {
        for level in 1...3 {
            let block = BlockContentFfi.heading(level: level, text: [])
            let data = try JSONEncoder().encode(block)
            let decoded = try JSONDecoder().decode(BlockContentFfi.self, from: data)
            if case .heading(let l, _) = decoded {
                #expect(l == level)
            } else {
                Issue.record("expected .heading at level \(level)")
            }
        }
    }
}
