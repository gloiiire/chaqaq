import Testing
import Foundation
@testable import Chaqaq

// Vérifie le round-trip Codable des miroirs Swift des types Rust.
// Le format JSON doit matcher exactement celui produit par serde côté Rust
// (sinon les bindings cassent silencieusement).

@Suite("InlineStyleFfi — round-trip JSON")
struct InlineStyleFfiTests {

    @Test func boldSerializesAsBareString() throws {
        let json = try encode(InlineStyleFfi.bold)
        #expect(json == "\"Bold\"")
    }

    @Test func italicSerializesAsBareString() throws {
        #expect(try encode(InlineStyleFfi.italic) == "\"Italic\"")
    }

    @Test func underlineSerializesAsBareString() throws {
        #expect(try encode(InlineStyleFfi.underline) == "\"Underline\"")
    }

    @Test func strikethroughSerializesAsBareString() throws {
        #expect(try encode(InlineStyleFfi.strikethrough) == "\"Strikethrough\"")
    }

    @Test func colorSerializesAsKeyedString() throws {
        let json = try encode(InlineStyleFfi.color("rouge"))
        #expect(json == "{\"Color\":\"rouge\"}")
    }

    @Test func linkSerializesAsKeyedString() throws {
        let json = try encode(InlineStyleFfi.link("https://chaqaq.app"))
        #expect(json == "{\"Link\":\"https:\\/\\/chaqaq.app\"}")
    }

    @Test func roundTripsAllVariants() throws {
        let originals: [InlineStyleFfi] = [
            .bold, .italic, .underline, .strikethrough,
            .color("bleu"), .link("https://x.com")
        ]
        for original in originals {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(InlineStyleFfi.self, from: data)
            let twice = try JSONEncoder().encode(decoded)
            #expect(data == twice, "le round-trip doit produire un JSON identique")
        }
    }
}

@Suite("BlockContentFfi — round-trip JSON + helpers")
struct BlockContentFfiTests {

    @Test func dividerSerializesAsBareString() throws {
        #expect(try encode(BlockContentFfi.divider) == "\"Divider\"")
    }

    @Test func headingHasLevelAndText() throws {
        let block = BlockContentFfi.heading(level: 2, text: [InlineTextFfi(content: "Titre", styles: [])])
        let decoded = try JSONDecoder().decode(BlockContentFfi.self, from: try JSONEncoder().encode(block))
        guard case .heading(let level, let text) = decoded else {
            Issue.record("expected .heading"); return
        }
        #expect(level == 2)
        #expect(text.first?.content == "Titre")
    }

    @Test func plainTextConcatenatesSpans() {
        let block = BlockContentFfi.text([
            InlineTextFfi(content: "Bon", styles: [.bold]),
            InlineTextFfi(content: "jour", styles: [])
        ])
        #expect(block.plainText == "Bonjour")
    }

    @Test func plainTextEmptyForDivider() {
        #expect(BlockContentFfi.divider.plainText == "")
    }

    @Test func isTodoOnlyForTodoVariant() {
        #expect(BlockContentFfi.todo(done: false, text: []).isTodo)
        #expect(!BlockContentFfi.text([]).isTodo)
    }

    @Test func isTodoDoneTrueOnlyForCheckedTodo() {
        #expect(BlockContentFfi.todo(done: true, text: []).isTodoDone)
        #expect(!BlockContentFfi.todo(done: false, text: []).isTodoDone)
        #expect(!BlockContentFfi.text([]).isTodoDone)
    }

    @Test func withTextReplacesContent() {
        let updated = BlockContentFfi.text([]).withText("salut")
        #expect(updated.plainText == "salut")
    }

    @Test func withSpansPreservesStructure() {
        let spans = [InlineTextFfi(content: "x", styles: [.bold])]
        guard case .heading(let level, let text) =
            BlockContentFfi.heading(level: 1, text: []).withSpans(spans) else {
            Issue.record("expected .heading"); return
        }
        #expect(level == 1)
        #expect(text.count == 1)
        #expect(text.first?.content == "x")
    }
}

// MARK: - Helpers

private func encode<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    return String(data: data, encoding: .utf8) ?? ""
}
