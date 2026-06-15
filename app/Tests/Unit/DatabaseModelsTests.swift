import Testing
import Foundation
import PinkhaFFI
@testable import Pinkha

// Tests for the Swift Codable mirrors of Rust database types.
// Every test verifies the exact JSON format that serde produces on the Rust side.

@Suite("PropertyTypeFfi — Codable round-trip")
struct PropertyTypeFfiTests {

    @Test func titleEncodesAsBareString() throws {
        #expect(try encode(PropertyTypeFfi.title) == "\"Title\"")
    }

    @Test func textEncodesAsBareString() throws {
        #expect(try encode(PropertyTypeFfi.text) == "\"Text\"")
    }

    @Test func numberEncodesAsBareString() throws {
        #expect(try encode(PropertyTypeFfi.number) == "\"Number\"")
    }

    @Test func checkboxEncodesAsBareString() throws {
        #expect(try encode(PropertyTypeFfi.checkbox) == "\"Checkbox\"")
    }

    @Test func dateEncodesAsBareString() throws {
        #expect(try encode(PropertyTypeFfi.date) == "\"Date\"")
    }

    @Test func urlEncodesAsBareString() throws {
        #expect(try encode(PropertyTypeFfi.url) == "\"Url\"")
    }

    @Test func selectionEncodesAsKeyedArray() throws {
        let json = try encode(PropertyTypeFfi.selection(["A", "B"]))
        #expect(json == "{\"Selection\":[\"A\",\"B\"]}")
    }

    @Test func selectionMultipleEncodesAsKeyedArray() throws {
        let json = try encode(PropertyTypeFfi.selectionMultiple(["X"]))
        #expect(json == "{\"SelectionMultiple\":[\"X\"]}")
    }

    @Test func relationEncodesWithDbId() throws {
        let id = "00000000-0000-0000-0000-000000000001"
        let json = try encode(PropertyTypeFfi.relation(dbId: id))
        #expect(json.contains("\"Relation\""))
        #expect(json.contains(id))
    }

    @Test func unitVariantsRoundTrip() throws {
        let variants: [PropertyTypeFfi] = [.title, .text, .number, .date, .checkbox, .url]
        for v in variants {
            let data    = try JSONEncoder().encode(v)
            let decoded = try JSONDecoder().decode(PropertyTypeFfi.self, from: data)
            #expect(decoded == v)
        }
    }

    @Test func selectionRoundTrips() throws {
        let orig = PropertyTypeFfi.selection(["Todo", "Done"])
        let data = try JSONEncoder().encode(orig)
        #expect(try JSONDecoder().decode(PropertyTypeFfi.self, from: data) == orig)
    }
}

@Suite("PropertyValueFfi — Codable round-trip")
struct PropertyValueFfiTests {

    @Test func emptyEncodesAsBareString() throws {
        #expect(try encode(PropertyValueFfi.empty) == "\"Empty\"")
    }

    @Test func textEncodesAsKeyedString() throws {
        #expect(try encode(PropertyValueFfi.text("hello")) == "{\"Text\":\"hello\"}")
    }

    @Test func numberEncodesAsKeyedDouble() throws {
        let json = try encode(PropertyValueFfi.number(3.14))
        #expect(json.contains("\"Number\""))
        #expect(json.contains("3.14"))
    }

    @Test func checkboxTrueEncodesCorrectly() throws {
        #expect(try encode(PropertyValueFfi.checkbox(true)) == "{\"Checkbox\":true}")
    }

    @Test func checkboxFalseEncodesCorrectly() throws {
        #expect(try encode(PropertyValueFfi.checkbox(false)) == "{\"Checkbox\":false}")
    }

    @Test func selectionNilEncodesAsNull() throws {
        let json = try encode(PropertyValueFfi.selection(nil))
        #expect(json == "{\"Selection\":null}")
    }

    @Test func selectionSomeEncodesAsString() throws {
        let json = try encode(PropertyValueFfi.selection("Done"))
        #expect(json == "{\"Selection\":\"Done\"}")
    }

    @Test func allVariantsRoundTrip() throws {
        let variants: [PropertyValueFfi] = [
            .empty,
            .text("hello"),
            .number(42),
            .checkbox(true),
            .checkbox(false),
            .selection(nil),
            .selection("In Progress"),
            .selectionMultiple(["A", "B"]),
            .date("2026-05-31"),
            .url("https://pinkha.app"),
            .relation(["uuid-1", "uuid-2"]),
        ]
        for v in variants {
            let data    = try JSONEncoder().encode(v)
            let decoded = try JSONDecoder().decode(PropertyValueFfi.self, from: data)
            #expect(decoded == v)
        }
    }
}

@Suite("PropertyFfi — Codable round-trip")
struct PropertyFfiTests {

    @Test func decodesFromRustStyleJson() throws {
        let json = """
        {"id":"some-uuid","name":"Status","type_":"Text"}
        """
        let prop = try JSONDecoder().decode(PropertyFfi.self, from: Data(json.utf8))
        #expect(prop.id == "some-uuid")
        #expect(prop.name == "Status")
        #expect(prop.propertyType == .text)
    }

    @Test func encodesWithTypeUnderscore() throws {
        let prop = PropertyFfi(id: "abc", name: "Done", propertyType: .checkbox)
        let json = try encode(prop)
        #expect(json.contains("\"type_\""))
        #expect(json.contains("\"Checkbox\""))
    }

    @Test func roundTripsAllPropertyTypes() throws {
        let types: [PropertyTypeFfi] = [.title, .text, .number, .checkbox, .date, .url, .selection(["A"])]
        for t in types {
            let prop    = PropertyFfi(id: UUID().uuidString, name: "Col", propertyType: t)
            let data    = try JSONEncoder().encode(prop)
            let decoded = try JSONDecoder().decode(PropertyFfi.self, from: data)
            #expect(decoded == prop)
        }
    }
}

@Suite("EntryFfi — Codable round-trip")
struct EntryFfiTests {

    @Test func decodesWithCreatedAtSnakeCase() throws {
        let json = """
        {"id":"entry-1","created_at":"2026-05-31T00:00:00Z","values":{}}
        """
        let entry = try JSONDecoder().decode(EntryFfi.self, from: Data(json.utf8))
        #expect(entry.id == "entry-1")
        #expect(entry.createdAt == "2026-05-31T00:00:00Z")
        #expect(entry.values.isEmpty)
    }

    @Test func decodesEntryWithTextValue() throws {
        let propId = "prop-uuid"
        let json = """
        {"id":"e1","created_at":"","values":{"\(propId)":{"Text":"My title"}}}
        """
        let entry = try JSONDecoder().decode(EntryFfi.self, from: Data(json.utf8))
        #expect(entry.values[propId] == .text("My title"))
    }

    @Test func decodesEntryWithCheckbox() throws {
        let propId = "cb-uuid"
        let json = """
        {"id":"e2","created_at":"","values":{"\(propId)":{"Checkbox":true}}}
        """
        let entry = try JSONDecoder().decode(EntryFfi.self, from: Data(json.utf8))
        #expect(entry.values[propId] == .checkbox(true))
    }

    /// Legacy entries serialised before `document_id` existed must still
    /// decode — mirrors the Rust `#[serde(default)]` guarantee.
    @Test func decodesLegacyEntryWithoutDocumentId() throws {
        let json = """
        {"id":"legacy","created_at":"","values":{}}
        """
        let entry = try JSONDecoder().decode(EntryFfi.self, from: Data(json.utf8))
        #expect(entry.documentId == nil)
    }

    @Test func decodesEntryWithDocumentLink() throws {
        let json = """
        {"id":"e3","created_at":"","values":{},"document_id":"doc-123"}
        """
        let entry = try JSONDecoder().decode(EntryFfi.self, from: Data(json.utf8))
        #expect(entry.documentId == "doc-123")
    }
}

@Suite("DatabaseFfi — Codable decoding")
struct DatabaseFfiTests {

    @Test func decodesEmptyDatabase() throws {
        let json = """
        {"id":"db-1","title":[{"content":"My DB","styles":[]}],"properties":[],"entries":[]}
        """
        let db = try JSONDecoder().decode(DatabaseFfi.self, from: Data(json.utf8))
        #expect(db.id == "db-1")
        #expect(db.title.first?.content == "My DB")
        #expect(db.properties.isEmpty)
        #expect(db.entries.isEmpty)
    }

    @Test func decodesWithOnePropertyAndOneEntry() throws {
        let propId = "00000000-0000-0000-0000-000000000001"
        let json = """
        {
          "id":"db-2",
          "title":[{"content":"Tasks","styles":[]}],
          "properties":[{"id":"\(propId)","name":"Name","type_":"Title"}],
          "entries":[{"id":"e1","created_at":"","values":{"\(propId)":{"Title":[{"content":"Fix bug","styles":[]}]}}}]
        }
        """
        let db = try JSONDecoder().decode(DatabaseFfi.self, from: Data(json.utf8))
        #expect(db.properties.count == 1)
        #expect(db.properties[0].name == "Name")
        #expect(db.entries.count == 1)
        if case .title(let spans) = db.entries[0].values[propId] {
            #expect(spans.first?.content == "Fix bug")
        } else {
            Issue.record("Expected title value")
        }
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

private func encode<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}
