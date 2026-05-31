import Testing
import Foundation
@testable import Pinkha

// Advanced database FFI: properties, entries, views.
// No UI yet, but the API must be correct (Notion-like preparation).

@Suite("Database — properties, entries, views via FFI")
struct DatabaseEntitiesTests {

    private func makeApi() throws -> (PinkhaApi, URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_dbent_\(UUID().uuidString).db")
        let api = try PinkhaApi(dbPath: tmp.path)
        let dbId = try api.createDatabase(title: "Test DB")
        return (api, tmp, dbId)
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
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        try api.addProperty(dbId: dbId, propertyJson: propertyJson(name: "Statut"))
    }

    @Test func addEntryWithEmptyValuesReturnsId() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        let entryId = try api.addEntry(dbId: dbId, valuesJson: "{}")
        #expect(UUID(uuidString: entryId) != nil)
    }

    @Test func deleteEntryRemovesIt() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        let entryId = try api.addEntry(dbId: dbId, valuesJson: "{}")
        try api.deleteEntry(dbId: dbId, entryId: entryId)
    }

    @Test func renamePropertyApplies() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        let propId = UUID().uuidString
        let json = "{\"id\":\"\(propId)\",\"name\":\"Avant\",\"type_\":\"Text\"}"
        try api.addProperty(dbId: dbId, propertyJson: json)
        try api.renameProperty(dbId: dbId, propertyId: propId, newName: "Après")
        let dbJson = try api.getDatabaseJson(id: dbId)
        #expect(dbJson.contains("Après"))
        #expect(!dbJson.contains("\"Avant\""))
    }

    @Test func deletePropertyRemovesIt() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        let propId = UUID().uuidString
        let json = "{\"id\":\"\(propId)\",\"name\":\"Temp\",\"type_\":\"Text\"}"
        try api.addProperty(dbId: dbId, propertyJson: json)
        try api.deleteProperty(dbId: dbId, propertyId: propId)
        let dbJson = try api.getDatabaseJson(id: dbId)
        #expect(!dbJson.contains(propId))
    }

    @Test func defaultDatabaseHasOneTableView() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        let dbJson = try api.getDatabaseJson(id: dbId)
        #expect(dbJson.contains("\"Table\""))
    }
}
