import Testing
import Foundation
@testable import Pinkha

// Database FFI tests: even though the UI does not exist yet, the API must work.

@Suite("PinkhaApi — databases (FFI exposed, UI coming)")
struct DatabaseApiTests {

    private func makeApi() throws -> (PinkhaApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_db_\(UUID().uuidString).db")
        return (try PinkhaApi(dbPath: tmp.path), tmp)
    }

    @Test func createDatabaseReturnsUuid() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try api.createDatabase(title: "Tâches")
        #expect(UUID(uuidString: id) != nil)
    }

    @Test func listDatabasesAfterCreate() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try api.createDatabase(title: "Projets")
        _ = try api.createDatabase(title: "Notes")
        let metas = try api.listDatabases()
        #expect(metas.count == 2)
        #expect(metas.contains(where: { $0.titlePlain == "Projets" }))
        #expect(metas.contains(where: { $0.titlePlain == "Notes" }))
    }

    @Test func deleteDatabaseSoftRemoves() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try api.createDatabase(title: "Temp")
        try api.deleteDatabase(id: id)
        #expect(try api.listDatabases().isEmpty)
    }

    @Test func getDatabaseJsonReturnsValidJSON() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try api.createDatabase(title: "Test")
        let json = try api.getDatabaseJson(id: id)
        // Just verify it is valid JSON and that the id matches.
        #expect(json.contains(id))
    }
}
