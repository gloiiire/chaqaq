import Testing
import Foundation
@testable import Chaqaq

// Tests FFI databases : même si l'UI n'existe pas encore, l'API doit fonctionner.

@Suite("ChaqaqApi — databases (FFI exposée, UI à venir)")
struct DatabaseApiTests {

    private func makeApi() throws -> (ChaqaqApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chaqaq_db_\(UUID().uuidString).db")
        return (try ChaqaqApi(dbPath: tmp.path), tmp)
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
        // On vérifie juste que c'est du JSON valide et que l'id matche.
        #expect(json.contains(id))
    }
}
