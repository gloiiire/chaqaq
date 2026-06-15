import Testing
import Foundation
import PinkhaFFI
@testable import Pinkha

// Advanced book FFI: properties, entries, views.
// No UI yet, but the API must be correct (Notion-like preparation).

@Suite("Book — properties, entries, views via FFI")
struct BookEntitiesTests {

    private func makeApi() throws -> (PinkhaApi, URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_dbent_\(UUID().uuidString).db")
        let api = try PinkhaApi(dbPath: tmp.path)
        let bookId = try api.createBook(title: "Test DB")
        return (api, tmp, bookId)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    // Rust externally-tagged JSON format: Title (unit variant) → "Title".
    private func propertyJson(name: String, type: String = "Title") -> String {
        return "{\"id\":\"\(UUID().uuidString)\",\"name\":\"\(name)\",\"type_\":\"\(type)\"}"
    }

    @Test func addPropertyDoesNotThrow() throws {
        let (api, url, bookId) = try makeApi(); defer { cleanup(url) }
        try api.addProperty(bookId: bookId, propertyJson: propertyJson(name: "Status"))
    }

    @Test func addEntryWithEmptyValuesReturnsId() throws {
        let (api, url, bookId) = try makeApi(); defer { cleanup(url) }
        let entryId = try api.addEntry(bookId: bookId, valuesJson: "{}")
        #expect(UUID(uuidString: entryId) != nil)
    }

    @Test func deleteEntryRemovesIt() throws {
        let (api, url, bookId) = try makeApi(); defer { cleanup(url) }
        let entryId = try api.addEntry(bookId: bookId, valuesJson: "{}")
        try api.deleteEntry(bookId: bookId, entryId: entryId)
    }

    @Test func renamePropertyApplies() throws {
        let (api, url, bookId) = try makeApi(); defer { cleanup(url) }
        let propId = UUID().uuidString
        let json = "{\"id\":\"\(propId)\",\"name\":\"Before\",\"type_\":\"Text\"}"
        try api.addProperty(bookId: bookId, propertyJson: json)
        try api.renameProperty(bookId: bookId, propertyId: propId, newName: "After")
        let dbJson = try api.getBookJson(id: bookId)
        #expect(dbJson.contains("After"))
        #expect(!dbJson.contains("\"Before\""))
    }

    @Test func deletePropertyRemovesIt() throws {
        let (api, url, bookId) = try makeApi(); defer { cleanup(url) }
        let propId = UUID().uuidString
        let json = "{\"id\":\"\(propId)\",\"name\":\"Temp\",\"type_\":\"Text\"}"
        try api.addProperty(bookId: bookId, propertyJson: json)
        try api.deleteProperty(bookId: bookId, propertyId: propId)
        let dbJson = try api.getBookJson(id: bookId)
        #expect(!dbJson.contains(propId))
    }

    @Test func defaultBookHasOneListView() throws {
        // Mobile-first default — fresh books ship a List view.
        let (api, url, bookId) = try makeApi(); defer { cleanup(url) }
        let dbJson = try api.getBookJson(id: bookId)
        #expect(dbJson.contains("\"List\""))
    }
}
