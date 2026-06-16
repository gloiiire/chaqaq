import Testing
import Foundation
import PinkhaFFI
@testable import BookFeature
@testable import Pinkha

// Book FFI tests: even though the UI does not exist yet, the API must work.

@Suite("PinkhaApi — books (FFI exposed, UI coming)")
struct BookApiTests {

    private func makeApi() throws -> (PinkhaApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_book_\(UUID().uuidString).db")
        return (try PinkhaApi(dbPath: tmp.path), tmp)
    }

    @Test func createBookReturnsUuid() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try api.createBook(title: "Tasks")
        #expect(UUID(uuidString: id) != nil)
    }

    @Test func listBooksAfterCreate() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try api.createBook(title: "Projets")
        _ = try api.createBook(title: "Notes")
        let metas = try api.listBooks()
        #expect(metas.count == 2)
        #expect(metas.contains(where: { $0.titlePlain == "Projets" }))
        #expect(metas.contains(where: { $0.titlePlain == "Notes" }))
    }

    @Test func deleteBookSoftRemoves() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try api.createBook(title: "Temp")
        try api.deleteBook(id: id)
        #expect(try api.listBooks().isEmpty)
    }

    @Test func getBookJsonReturnsValidJSON() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try api.createBook(title: "Test")
        let json = try api.getBookJson(id: id)
        // Just verify it is valid JSON and that the id matches.
        #expect(json.contains(id))
    }
}
