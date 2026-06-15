import Testing
import Foundation
import PinkhaFFI
@testable import Pinkha

@Suite("Search — document and block search")
struct SearchTests {

    private func makeApi() throws -> (PinkhaApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_search_\(UUID().uuidString).db")
        return (try PinkhaApi(dbPath: tmp.path), tmp)
    }

    private func textBlock(_ s: String) throws -> String {
        let c = BlockContentFfi.text([InlineTextFfi(content: s, styles: [])])
        return try String(data: JSONEncoder().encode(c), encoding: .utf8)!
    }

    @Test func searchDocumentsCaseInsensitive() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try api.createDocument(title: "Trip to Paris")
        _ = try api.createDocument(title: "Good restaurants")

        #expect(try api.searchDocuments(query: "paris").count == 1)
        #expect(try api.searchDocuments(query: "PARIS").count == 1)
        #expect(try api.searchDocuments(query: "restaurant").count == 1)
        #expect(try api.searchDocuments(query: "tokyo").isEmpty)
    }

    @Test func searchDocumentsEmptyQueryMatchesAll() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try api.createDocument(title: "A")
        _ = try api.createDocument(title: "B")
        // An empty string is contained in every title — standard `contains` behaviour.
        #expect(try api.searchDocuments(query: "").count == 2)
    }

    @Test func searchInBlocksFindsThroughBlockContent() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        let docId = try api.createDocument(title: "Empty")
        _ = try api.addBlock(docId: docId, blockContentJson: try textBlock("Rust is great"))

        let hits = try api.searchInBlocks(query: "rust")
        #expect(hits.contains(where: { $0.id == docId }))
        #expect(try api.searchInBlocks(query: "swift").isEmpty)
    }
}
