import Testing
import Foundation
@testable import Pinkha

// Tests for the pure mapping logic in NotionImporter — no network, no SQLite.

@MainActor
@Suite("NotionImporter — mapping logic")
struct NotionMappingTests {

    private let importer = NotionImporter()

    // ── extractId ─────────────────────────────────────────────────────────────

    @Test func extractIdFromBareHex() {
        let id = importer.extractId(from: "334b2e16a3008111a62dca569edcc84c")
        #expect(id == "334b2e16a3008111a62dca569edcc84c")
    }

    @Test func extractIdFromDashedUUID() {
        let id = importer.extractId(from: "334b2e16-a300-8111-a62d-ca569edcc84c")
        #expect(id == "334b2e16a3008111a62dca569edcc84c")
    }

    @Test func extractIdFromNotionURL() {
        let url = "https://www.notion.so/334b2e16a3008111a62dca569edcc84c"
        #expect(importer.extractId(from: url) == "334b2e16a3008111a62dca569edcc84c")
    }

    @Test func extractIdStripsQueryParams() {
        let url = "https://www.notion.so/334b2e16a3008111a62dca569edcc84c?pvs=1"
        #expect(importer.extractId(from: url) == "334b2e16a3008111a62dca569edcc84c")
    }

    @Test func extractIdFromURLWithPath() {
        let url = "https://www.notion.so/workspace/Title-334b2e16a3008111a62dca569edcc84c"
        #expect(importer.extractId(from: url) == "334b2e16a3008111a62dca569edcc84c")
    }

    // ── mapType ───────────────────────────────────────────────────────────────

    @Test func mapTypeTitle() {
        let def = makePropertyDef(type: "title")
        #expect(importer.mapType(def) == .title)
    }

    @Test func mapTypeRichText() {
        let def = makePropertyDef(type: "rich_text")
        #expect(importer.mapType(def) == .text)
    }

    @Test func mapTypeNumber() {
        #expect(importer.mapType(makePropertyDef(type: "number")) == .number)
    }

    @Test func mapTypeCheckbox() {
        #expect(importer.mapType(makePropertyDef(type: "checkbox")) == .checkbox)
    }

    @Test func mapTypeDate() {
        #expect(importer.mapType(makePropertyDef(type: "date")) == .date)
    }

    @Test func mapTypeUrl() {
        #expect(importer.mapType(makePropertyDef(type: "url")) == .url)
    }

    @Test func mapTypeSelectExtractsOptions() {
        let def = NotionPropertyDef(
            id: "p1", name: "Dimension", type: "select",
            select: NotionSelectConfig(options: [
                NotionOption(name: "Psalms", color: "red"),
                NotionOption(name: "Vision", color: "purple")
            ]),
            multiSelect: nil
        )
        #expect(importer.mapType(def) == .selection(["Psalms", "Vision"]))
    }

    @Test func mapTypeMultiSelectExtractsOptions() {
        let def = NotionPropertyDef(
            id: "p2", name: "Sujet", type: "multi_select",
            select: nil,
            multiSelect: NotionMultiSelectConfig(options: [
                NotionOption(name: "Partie 0", color: "yellow"),
                NotionOption(name: "Partie 1", color: "yellow")
            ])
        )
        #expect(importer.mapType(def) == .selectionMultiple(["Partie 0", "Partie 1"]))
    }

    @Test func mapTypeSelectEmptyWhenNoConfig() {
        let def = makePropertyDef(type: "select")
        #expect(importer.mapType(def) == .selection([]))
    }

    @Test func mapTypeUnknownFallsBackToText() {
        #expect(importer.mapType(makePropertyDef(type: "formula")) == .text)
        #expect(importer.mapType(makePropertyDef(type: "relation")) == .text)
    }

    // ── mapValue ──────────────────────────────────────────────────────────────

    @Test func mapValueTitle() {
        let spans = [NotionRichText(plainText: "My Entry")]
        let result = importer.mapValue(.title(spans))
        #expect(result == .title([InlineTextFfi(content: "My Entry", styles: [])]))
    }

    @Test func mapValueRichText() {
        #expect(importer.mapValue(.richText([NotionRichText(plainText: "hello")])) == .text("hello"))
    }

    @Test func mapValueRichTextEmpty() {
        #expect(importer.mapValue(.richText([])) == .empty)
    }

    @Test func mapValueNumber() {
        #expect(importer.mapValue(.number(42.0)) == .number(42))
        #expect(importer.mapValue(.number(nil)) == .empty)
    }

    @Test func mapValueSelect() {
        #expect(importer.mapValue(.select("Psalms")) == .selection("Psalms"))
        #expect(importer.mapValue(.select(nil)) == .selection(nil))
    }

    @Test func mapValueMultiSelect() {
        #expect(importer.mapValue(.multiSelect(["A", "B"])) == .selectionMultiple(["A", "B"]))
        #expect(importer.mapValue(.multiSelect([])) == .empty)
    }

    @Test func mapValueDate() {
        #expect(importer.mapValue(.date("2024-03-15")) == .date("2024-03-15"))
        #expect(importer.mapValue(.date(nil)) == .empty)
    }

    @Test func mapValueCheckbox() {
        #expect(importer.mapValue(.checkbox(true)) == .checkbox(true))
        #expect(importer.mapValue(.checkbox(false)) == .checkbox(false))
    }

    @Test func mapValueUrl() {
        #expect(importer.mapValue(.url("https://example.com")) == .url("https://example.com"))
        #expect(importer.mapValue(.url(nil)) == .empty)
    }

    @Test func mapValueUnknownReturnsNil() {
        #expect(importer.mapValue(.unknown) == nil)
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func makePropertyDef(type: String) -> NotionPropertyDef {
        NotionPropertyDef(id: "id", name: "Prop", type: type, select: nil, multiSelect: nil)
    }
}
