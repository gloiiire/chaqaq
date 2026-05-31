import Testing
import Foundation
@testable import Pinkha

@Suite("JSON malformé — robustesse decode")
struct MalformedJSONTests {

    @Test func unknownInlineStyleThrows() {
        let badJson = "\"Pasunestyle\""
        let data = badJson.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(InlineStyleFfi.self, from: data)
        }
    }

    @Test func emptyJsonObjectThrowsForBlockContent() {
        let data = "{}".data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(BlockContentFfi.self, from: data)
        }
    }

    @Test func malformedHeadingMissingLevelThrows() {
        let badJson = "{\"Heading\": {\"text\": []}}"
        let data = badJson.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(BlockContentFfi.self, from: data)
        }
    }

    @Test func malformedTodoMissingDoneThrows() {
        let badJson = "{\"Todo\": {\"text\": []}}"
        let data = badJson.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(BlockContentFfi.self, from: data)
        }
    }

    @Test func validDividerStringDecodes() throws {
        let data = "\"Divider\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BlockContentFfi.self, from: data)
        if case .divider = decoded {} else {
            Issue.record("expected .divider")
        }
    }

    @Test func validBreadcrumbStringDecodes() throws {
        let data = "\"Breadcrumb\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BlockContentFfi.self, from: data)
        if case .breadcrumb = decoded {} else {
            Issue.record("expected .breadcrumb")
        }
    }

    @Test func inlineTextMissingContentThrows() {
        let data = "{\"styles\":[]}".data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(InlineTextFfi.self, from: data)
        }
    }

    @Test func styleAliasFromRustOldFormat() throws {
        // L'ancien format pouvait sérialiser "style" au lieu de "styles" pour InlineText.
        // Le Rust gère cela via #[serde(alias = "style")] côté domaine. Le miroir Swift
        // ne le supporte pas (alias serde n'a pas d'équivalent direct), mais on documente
        // le comportement actuel : le décodeur Swift exige "styles".
        let data = "{\"content\":\"x\",\"style\":[]}".data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(InlineTextFfi.self, from: data)
        }
    }
}
