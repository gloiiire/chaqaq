import Testing
import Foundation
import PinkhaFFI
@testable import Pinkha

@Suite("Search — leaf and block search")
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

    @Test func searchLeavesCaseInsensitive() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try api.createLeaf(title: "Trip to Paris")
        _ = try api.createLeaf(title: "Good restaurants")

        #expect(try api.searchLeaves(query: "paris").count == 1)
        #expect(try api.searchLeaves(query: "PARIS").count == 1)
        #expect(try api.searchLeaves(query: "restaurant").count == 1)
        #expect(try api.searchLeaves(query: "tokyo").isEmpty)
    }

    @Test func searchLeavesEmptyQueryMatchesAll() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try api.createLeaf(title: "A")
        _ = try api.createLeaf(title: "B")
        // An empty string is contained in every title — standard `contains` behaviour.
        #expect(try api.searchLeaves(query: "").count == 2)
    }

    @Test func searchInBlocksFindsThroughBlockContent() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        let leafId = try api.createLeaf(title: "Empty")
        _ = try api.addBlock(leafId: leafId, blockContentJson: try textBlock("Rust is great"))

        let hits = try api.searchInBlocks(query: "rust")
        #expect(hits.contains(where: { $0.id == leafId }))
        #expect(try api.searchInBlocks(query: "swift").isEmpty)
    }
}
