import Testing
import Foundation
import PinkhaFFI
@testable import Pinkha

// Unit tests for the three block variants added in the latest iteration:
// BulletedListItem, NumberedListItem, Code.
// The existing ModelsTests.swift covers Text/Heading/Quote/Todo/Divider — no overlap here.

@Suite("BlockContentFfi Codable — BulletedListItem, NumberedListItem, Code")
struct BlockContentFfiCodableTests {

    // MARK: - BulletedListItem

    @Test func bulletedListItem_roundtrip() throws {
        let spans = [
            InlineTextFfi(content: "First point", styles: [.bold]),
            InlineTextFfi(content: " — detail", styles: [])
        ]
        let original = BlockContentFfi.bulletedListItem(spans)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BlockContentFfi.self, from: data)

        guard case .bulletedListItem(let result) = decoded else {
            Issue.record("expected .bulletedListItem, got \(decoded)"); return
        }
        #expect(result.count == 2)
        #expect(result[0].content == "First point")
        #expect(result[0].styles == [.bold])
        #expect(result[1].content == " — detail")
        #expect(result[1].styles.isEmpty)
    }

    @Test func bulletedListItem_empty_spans_roundtrip() throws {
        let original = BlockContentFfi.bulletedListItem([])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BlockContentFfi.self, from: data)
        guard case .bulletedListItem(let result) = decoded else {
            Issue.record("expected .bulletedListItem"); return
        }
        #expect(result.isEmpty)
    }

    @Test func bulletedListItem_plainText_concatenates_spans() {
        let block = BlockContentFfi.bulletedListItem([
            InlineTextFfi(content: "A", styles: []),
            InlineTextFfi(content: "B", styles: [.italic])
        ])
        #expect(block.plainText == "AB")
    }

    @Test func bulletedListItem_spansOrEmpty_returns_spans() {
        let spans = [InlineTextFfi(content: "hello", styles: [])]
        let block = BlockContentFfi.bulletedListItem(spans)
        #expect(block.spansOrEmpty == spans)
    }

    // MARK: - NumberedListItem

    @Test func numberedListItem_roundtrip() throws {
        let spans = [
            InlineTextFfi(content: "Step one", styles: []),
            InlineTextFfi(content: " (important)", styles: [.bold, .italic])
        ]
        let original = BlockContentFfi.numberedListItem(spans)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BlockContentFfi.self, from: data)

        guard case .numberedListItem(let result) = decoded else {
            Issue.record("expected .numberedListItem, got \(decoded)"); return
        }
        #expect(result.count == 2)
        #expect(result[1].styles.count == 2)
    }

    @Test func numberedListItem_plainText_concatenates_spans() {
        let block = BlockContentFfi.numberedListItem([
            InlineTextFfi(content: "One", styles: []),
            InlineTextFfi(content: "Two", styles: [])
        ])
        #expect(block.plainText == "OneTwo")
    }

    @Test func numberedListItem_spansOrEmpty_returns_spans() {
        let spans = [InlineTextFfi(content: "step", styles: [])]
        #expect(BlockContentFfi.numberedListItem(spans).spansOrEmpty == spans)
    }

    // MARK: - Code

    @Test func code_roundtrip() throws {
        let original = BlockContentFfi.code(language: "rust", text: "fn main() {}")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BlockContentFfi.self, from: data)

        guard case .code(let language, let text) = decoded else {
            Issue.record("expected .code, got \(decoded)"); return
        }
        #expect(language == "rust")
        #expect(text == "fn main() {}")
    }

    @Test func code_preserves_multiline_text() throws {
        let multiline = "let x = 1\nlet y = 2\nprint(x + y)"
        let original = BlockContentFfi.code(language: "swift", text: multiline)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BlockContentFfi.self, from: data)
        guard case .code(_, let text) = decoded else {
            Issue.record("expected .code"); return
        }
        #expect(text == multiline)
    }

    @Test func code_plainText_returns_text_field() {
        let block = BlockContentFfi.code(language: "python", text: "print('hello')")
        #expect(block.plainText == "print('hello')")
    }

    @Test func code_spansOrEmpty_returns_empty() {
        // Code blocks have no inline spans — spansOrEmpty must be empty.
        let block = BlockContentFfi.code(language: "rust", text: "fn main() {}")
        #expect(block.spansOrEmpty.isEmpty)
    }

    // MARK: - Decode from serde-produced JSON shapes

    @Test func decode_from_serde_bulleted() throws {
        // Serde externally-tagged format: {"BulletedListItem": [...]}
        let json = """
        {"BulletedListItem":[{"content":"hello","styles":[]}]}
        """
        let decoded = try JSONDecoder().decode(BlockContentFfi.self, from: Data(json.utf8))
        guard case .bulletedListItem(let spans) = decoded else {
            Issue.record("expected .bulletedListItem"); return
        }
        #expect(spans.count == 1)
        #expect(spans[0].content == "hello")
        #expect(spans[0].styles.isEmpty)
    }

    @Test func decode_from_serde_numbered() throws {
        let json = """
        {"NumberedListItem":[{"content":"item one","styles":["Bold"]}]}
        """
        let decoded = try JSONDecoder().decode(BlockContentFfi.self, from: Data(json.utf8))
        guard case .numberedListItem(let spans) = decoded else {
            Issue.record("expected .numberedListItem"); return
        }
        #expect(spans.count == 1)
        #expect(spans[0].content == "item one")
        #expect(spans[0].styles == [.bold])
    }

    @Test func decode_from_serde_code() throws {
        // Serde externally-tagged format: {"Code": {"language": "...", "text": "..."}}
        let json = """
        {"Code":{"language":"swift","text":"let x = 1"}}
        """
        let decoded = try JSONDecoder().decode(BlockContentFfi.self, from: Data(json.utf8))
        guard case .code(let language, let text) = decoded else {
            Issue.record("expected .code"); return
        }
        #expect(language == "swift")
        #expect(text == "let x = 1")
    }

    // MARK: - withText / withSpans structural preservation

    @Test func bulletedListItem_withText_replaces_content() {
        let updated = BlockContentFfi.bulletedListItem([]).withText("new point")
        guard case .bulletedListItem(let spans) = updated else {
            Issue.record("expected .bulletedListItem"); return
        }
        #expect(spans.first?.content == "new point")
    }

    @Test func numberedListItem_withSpans_replaces_spans() {
        let spans = [InlineTextFfi(content: "x", styles: [.underline])]
        let updated = BlockContentFfi.numberedListItem([]).withSpans(spans)
        guard case .numberedListItem(let result) = updated else {
            Issue.record("expected .numberedListItem"); return
        }
        #expect(result == spans)
    }
}
