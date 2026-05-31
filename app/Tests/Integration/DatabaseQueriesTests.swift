import Testing
import Foundation
@testable import Pinkha

// Advanced database FFI coverage: views, queries, aggregates, grouped queries.

@Suite("Database queries — views, aggregates, grouping")
struct DatabaseQueriesTests {

    private func makeApi() throws -> (PinkhaApi, URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_dbq_\(UUID().uuidString).db")
        let api = try PinkhaApi(dbPath: tmp.path)
        let dbId = try api.createDatabase(title: "Q")
        return (api, tmp, dbId)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    @Test func queryDefaultViewReturnsAllEntries() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        _ = try api.addEntry(dbId: dbId, valuesJson: "{}")
        _ = try api.addEntry(dbId: dbId, valuesJson: "{}")

        // Retrieve the default view id.
        let dbJson = try api.getDatabaseJson(id: dbId)
        guard let viewId = extractFirstViewId(dbJson) else {
            Issue.record("default view not found"); return
        }
        let resultJson = try api.queryDatabaseJson(dbId: dbId, viewId: viewId)
        // The JSON must be an array of 2 entries.
        let array = try JSONSerialization.jsonObject(with: resultJson.data(using: .utf8)!) as? [Any]
        #expect(array?.count == 2)
    }

    @Test func addViewReturnsUuid() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        let viewJson = """
        {"id":"\(UUID().uuidString)","name":"Kanban view","type_":{"Kanban":{"group_by":"00000000-0000-0000-0000-000000000000"}},"filters":[],"sorts":[]}
        """
        let viewId = try api.addView(dbId: dbId, viewJson: viewJson)
        #expect(UUID(uuidString: viewId) != nil)
    }

    @Test func deleteAllViewsExceptDefaultFailsOnLast() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        let dbJson = try api.getDatabaseJson(id: dbId)
        guard let viewId = extractFirstViewId(dbJson) else {
            Issue.record("default view not found"); return
        }
        // Business rule: the last view cannot be deleted.
        #expect(throws: PinkhaError.self) {
            try api.deleteView(dbId: dbId, viewId: viewId)
        }
    }

    @Test func updateViewWithEmptyFiltersAndSortsClears() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        let dbJson = try api.getDatabaseJson(id: dbId)
        guard let viewId = extractFirstViewId(dbJson) else {
            Issue.record("default view not found"); return
        }
        try api.updateView(dbId: dbId, viewId: viewId, filtersJson: "[]", sortsJson: "[]")
        // No error = OK
    }

    @Test func queryWithRollupsWorksOnEmptyDatabase() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        let dbJson = try api.getDatabaseJson(id: dbId)
        guard let viewId = extractFirstViewId(dbJson) else {
            Issue.record("default view not found"); return
        }
        let result = try api.queryDatabaseWithRollupsJson(dbId: dbId, viewId: viewId)
        #expect(result == "[]")
    }

    @Test func columnAggregateOnNumberProperty() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        let propId = UUID().uuidString
        let propJson = "{\"id\":\"\(propId)\",\"name\":\"Score\",\"type_\":\"Number\"}"
        try api.addProperty(dbId: dbId, propertyJson: propJson)

        // Entry with a Number value.
        let entryJson = "{\"\(propId)\":{\"Number\":42.0}}"
        _ = try api.addEntry(dbId: dbId, valuesJson: entryJson)

        // Count aggregate (alias Count after the rename).
        let aggregateJson = "\"Count\""
        let result = try api.columnAggregateDatabaseJson(
            dbId: dbId, propertyId: propId, aggregateJson: aggregateJson
        )
        // Must contain "1" (1 entry).
        #expect(result.contains("1"))
    }

    @Test func searchEntriesFindsByText() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        let propId = UUID().uuidString
        let propJson = "{\"id\":\"\(propId)\",\"name\":\"Note\",\"type_\":\"Text\"}"
        try api.addProperty(dbId: dbId, propertyJson: propJson)

        let entryJson = "{\"\(propId)\":{\"Text\":\"Bonjour le monde\"}}"
        _ = try api.addEntry(dbId: dbId, valuesJson: entryJson)

        let results = try api.searchDatabaseEntriesJson(dbId: dbId, query: "bonjour")
        #expect(results.contains("Bonjour le monde"))
    }

    // Extracts the first `id` from the first view in the database JSON.
    // Naive search: "views":[{"id":"<uuid>", ...
    private func extractFirstViewId(_ dbJson: String) -> String? {
        guard let viewsRange = dbJson.range(of: "\"views\":[") else { return nil }
        let after = dbJson[viewsRange.upperBound...]
        guard let idStart = after.range(of: "\"id\":\""),
              let idEnd = after.range(of: "\"", range: idStart.upperBound..<after.endIndex)
        else { return nil }
        return String(after[idStart.upperBound..<idEnd.lowerBound])
    }
}
