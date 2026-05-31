import Testing
import Foundation
@testable import Pinkha

@Suite("Performance — realistic loads (smoke tests)")
struct PerformanceTests {

    private func makeApi() throws -> (PinkhaApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_perf_\(UUID().uuidString).db")
        return (try PinkhaApi(dbPath: tmp.path), tmp)
    }

    @Test func canHandleThousandBlocks() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        let docId = try api.createDocument(title: "Stress")
        let c = BlockContentFfi.text([InlineTextFfi(content: "x", styles: [])])
        let json = String(data: try JSONEncoder().encode(c), encoding: .utf8)!

        let start = Date()
        for _ in 0..<1000 {
            _ = try api.addBlock(docId: docId, blockContentJson: json)
        }
        let elapsed = Date().timeIntervalSince(start)
        // Smoke: not a real perf measurement, but must stay under 30s.
        #expect(elapsed < 30, "1000 add_block must complete in < 30s, observed: \(elapsed)s")

        let doc = try JSONDecoder().decode(
            DocumentFfi.self,
            from: try api.getDocumentJson(id: docId).data(using: .utf8)!
        )
        #expect(doc.blocks.count == 1000)
    }

    @Test func canHandleHundredDocuments() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        for i in 0..<100 {
            _ = try api.createDocument(title: "Doc \(i)")
        }
        #expect(try api.listDocuments().count == 100)
    }

    @Test func loadOfDocWithManyBlocksStaysReasonable() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        let docId = try api.createDocument(title: "Loadtest")
        let c = BlockContentFfi.text([InlineTextFfi(content: "x", styles: [])])
        let json = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        for _ in 0..<500 {
            _ = try api.addBlock(docId: docId, blockContentJson: json)
        }
        let start = Date()
        let docJson = try api.getDocumentJson(id: docId)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "load must stay < 1s even with 500 blocks, observed: \(elapsed)s")
        #expect(!docJson.isEmpty)
    }
}
