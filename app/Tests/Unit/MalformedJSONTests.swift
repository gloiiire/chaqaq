import Testing
import Foundation
import PinkhaFFI
@testable import Pinkha

@Suite("Malformed JSON — decode robustness")
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
        // The old format could serialize "style" instead of "styles" for InlineText.
        // Rust handles this via #[serde(alias = "style")] on the domain side. The Swift mirror
        // does not support this (serde alias has no direct Swift equivalent), but we document
        // the current behaviour: the Swift decoder requires "styles".
        let data = "{\"content\":\"x\",\"style\":[]}".data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(InlineTextFfi.self, from: data)
        }
    }
}
