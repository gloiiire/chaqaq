import Testing
import Foundation
@testable import Chaqaq

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

@Suite("DocumentFfi — round-trip JSON complet")
struct DocumentFfiTests {

    @Test func emptyDocumentRoundTrips() throws {
        let id = UUID().uuidString
        let doc = DocumentFfi(id: id, cover: nil, title: [], blocks: [])
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(DocumentFfi.self, from: data)
        #expect(decoded.id == id)
        #expect(decoded.cover == nil)
        #expect(decoded.title.isEmpty)
        #expect(decoded.blocks.isEmpty)
    }

    @Test func documentWithCoverEncodes() throws {
        let doc = DocumentFfi(id: "x", cover: "aurora.jpg", title: [], blocks: [])
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(DocumentFfi.self, from: data)
        #expect(decoded.cover == "aurora.jpg")
    }

    @Test func documentWithBlocksRoundTrips() throws {
        let block = BlockFfi(
            id: "b1",
            content: .text([InlineTextFfi(content: "Hello", styles: [.bold])]),
            children: []
        )
        let doc = DocumentFfi(id: "d1", cover: nil,
                              title: [InlineTextFfi(content: "Titre", styles: [])],
                              blocks: [block])
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(DocumentFfi.self, from: data)
        #expect(decoded.blocks.count == 1)
        #expect(decoded.blocks[0].id == "b1")
        #expect(decoded.blocks[0].content.plainText == "Hello")
    }

    @Test func nestedChildrenRoundTrip() throws {
        let child = BlockFfi(id: "c", content: .text([]), children: [])
        let parent = BlockFfi(id: "p", content: .text([]), children: [child])
        let doc = DocumentFfi(id: "d", cover: nil, title: [], blocks: [parent])
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(DocumentFfi.self, from: data)
        #expect(decoded.blocks[0].children.count == 1)
        #expect(decoded.blocks[0].children[0].id == "c")
    }
}

@Suite("BlockContentFfi — toutes les variantes payload")
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
