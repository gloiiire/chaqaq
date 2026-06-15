import Testing
import Foundation
import PinkhaFFI
@testable import Pinkha

@Suite("Document operations — edge cases")
struct EdgeOpsTests {

    private func makeApi() throws -> (PinkhaApi, URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_edgeops_\(UUID().uuidString).db")
        let api = try PinkhaApi(dbPath: tmp.path)
        let docId = try api.createDocument(title: "Edge")
        return (api, tmp, docId)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    private func textJson(_ s: String) throws -> String {
        let c = BlockContentFfi.text([InlineTextFfi(content: s, styles: [])])
        return try String(data: JSONEncoder().encode(c), encoding: .utf8)!
    }

    @Test func updateDocumentTitleToEmpty() throws {
        let (api, url, docId) = try makeApi(); defer { cleanup(url) }
        try api.updateDocumentTitle(id: docId, newTitle: "")
        let metas = try api.listDocuments()
        #expect(metas.first?.titlePlain == "")
    }

    @Test func addDeleteThenReaddBlockSucceeds() throws {
        let (api, url, docId) = try makeApi(); defer { cleanup(url) }
        let json = try textJson("A")
        let id1 = try api.addBlock(docId: docId, blockContentJson: json)
        try api.deleteBlock(docId: docId, blockId: id1)
        let id2 = try api.addBlock(docId: docId, blockContentJson: json)
        #expect(id1 != id2, "le nouveau bloc doit avoir un UUID distinct")
    }

    @Test func reorderWithMissingIdsIgnoresThem() throws {
        let (api, url, docId) = try makeApi(); defer { cleanup(url) }
        let json = try textJson("A")
        let a = try api.addBlock(docId: docId, blockContentJson: json)
        let b = try api.addBlock(docId: docId, blockContentJson: json)
        let fakeId = UUID().uuidString
        // The order contains an unknown UUID — it must be ignored, b and a reordered.
        try api.reorderBlocks(docId: docId, order: [fakeId, b, a])
        let doc = try JSONDecoder().decode(
            DocumentFfi.self,
            from: try api.getDocumentJson(id: docId).data(using: .utf8)!
        )
        #expect(doc.blocks.map(\.id) == [b, a])
    }

    @Test func reorderWithPartialOrderKeepsRest() throws {
        let (api, url, docId) = try makeApi(); defer { cleanup(url) }
        let json = try textJson("A")
        let a = try api.addBlock(docId: docId, blockContentJson: json)
        let b = try api.addBlock(docId: docId, blockContentJson: json)
        let c = try api.addBlock(docId: docId, blockContentJson: json)
        // Only mentions c, a → b must be kept at the end.
        try api.reorderBlocks(docId: docId, order: [c, a])
        let doc = try JSONDecoder().decode(
            DocumentFfi.self,
            from: try api.getDocumentJson(id: docId).data(using: .utf8)!
        )
        #expect(doc.blocks.map(\.id) == [c, a, b])
    }

    @Test func deleteAlreadyDeletedThrowsNotFound() throws {
        let (api, url, docId) = try makeApi(); defer { cleanup(url) }
        let id = try api.addBlock(docId: docId, blockContentJson: try textJson("x"))
        try api.deleteBlock(docId: docId, blockId: id)
        #expect(throws: PinkhaError.self) {
            try api.deleteBlock(docId: docId, blockId: id)
        }
    }

    @Test func searchWithSpecialCharactersDoesNotCrash() throws {
        let (api, url, docId) = try makeApi(); defer { cleanup(url) }
        _ = try api.addBlock(docId: docId, blockContentJson: try textJson("contenu normal"))
        // Special characters in the query: must not crash.
        _ = try api.searchInBlocks(query: "%_'\\\"")
        _ = try api.searchInBlocks(query: "🎯")
    }
}
