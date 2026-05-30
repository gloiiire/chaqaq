import Testing
import Foundation
@testable import Chaqaq

// Couverture FFI database avancée : views, queries, aggregates, grouped queries.

@Suite("Database queries — views, aggregates, grouping")
struct DatabaseQueriesTests {

    private func makeApi() throws -> (ChaqaqApi, URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chaqaq_dbq_\(UUID().uuidString).db")
        let api = try ChaqaqApi(dbPath: tmp.path)
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

        // Récupère l'id de la vue par défaut.
        let dbJson = try api.getDatabaseJson(id: dbId)
        guard let viewId = extractFirstViewId(dbJson) else {
            Issue.record("vue par défaut introuvable"); return
        }
        let resultJson = try api.queryDatabaseJson(dbId: dbId, viewId: viewId)
        // Le JSON doit être un tableau de 2 entrées.
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
            Issue.record("vue par défaut introuvable"); return
        }
        // La règle métier : on ne peut pas supprimer la dernière vue.
        #expect(throws: ChaqaqError.self) {
            try api.deleteView(dbId: dbId, viewId: viewId)
        }
    }

    @Test func updateViewWithEmptyFiltersAndSortsClears() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        let dbJson = try api.getDatabaseJson(id: dbId)
        guard let viewId = extractFirstViewId(dbJson) else {
            Issue.record("vue par défaut introuvable"); return
        }
        try api.updateView(dbId: dbId, viewId: viewId, filtersJson: "[]", sortsJson: "[]")
        // Pas d'erreur = OK
    }

    @Test func queryWithRollupsWorksOnEmptyDatabase() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        let dbJson = try api.getDatabaseJson(id: dbId)
        guard let viewId = extractFirstViewId(dbJson) else {
            Issue.record("vue par défaut introuvable"); return
        }
        let result = try api.queryDatabaseWithRollupsJson(dbId: dbId, viewId: viewId)
        #expect(result == "[]")
    }

    @Test func columnAggregateOnNumberProperty() throws {
        let (api, url, dbId) = try makeApi(); defer { cleanup(url) }
        let propId = UUID().uuidString
        let propJson = "{\"id\":\"\(propId)\",\"name\":\"Score\",\"type_\":\"Number\"}"
        try api.addProperty(dbId: dbId, propertyJson: propJson)

        // Entrée avec une valeur Number.
        let entryJson = "{\"\(propId)\":{\"Number\":42.0}}"
        _ = try api.addEntry(dbId: dbId, valuesJson: entryJson)

        // Agrégat Compter (alias Count après le rename).
        let aggregateJson = "\"Count\""
        let result = try api.columnAggregateDatabaseJson(
            dbId: dbId, propertyId: propId, aggregateJson: aggregateJson
        )
        // Doit contenir "1" (1 entrée).
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

    // Extrait le premier `id` de la première vue du JSON database.
    // Recherche naïve : "views":[{"id":"<uuid>", ...
    private func extractFirstViewId(_ dbJson: String) -> String? {
        guard let viewsRange = dbJson.range(of: "\"views\":[") else { return nil }
        let after = dbJson[viewsRange.upperBound...]
        guard let idStart = after.range(of: "\"id\":\""),
              let idEnd = after.range(of: "\"", range: idStart.upperBound..<after.endIndex)
        else { return nil }
        return String(after[idStart.upperBound..<idEnd.lowerBound])
    }
}
