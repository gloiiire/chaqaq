import Testing
import Foundation
@testable import Chaqaq

// Tests d'intégration : validation aux frontières FFI (limites payload/UUID).

@Suite("FFI — validation aux frontières")
struct FFIBoundaryTests {

    private func makeApi() throws -> (ChaqaqApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chaqaq_test_\(UUID().uuidString).db")
        return (try ChaqaqApi(dbPath: tmp.path), tmp)
    }

    @Test func invalidUuidRejectedAsInvalidOperation() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ChaqaqError.self) {
            _ = try api.getDocumentJson(id: "pas-un-uuid")
        }
    }

    @Test func oversizedTitleRejected() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }

        // 128 Ko > MAX_STRING_BYTES (64 Ko)
        let huge = String(repeating: "a", count: 128 * 1024)
        #expect(throws: ChaqaqError.self) {
            _ = try api.createDocument(title: huge)
        }
    }

    @Test func oversizedJsonPayloadRejected() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }

        let docId = try api.createDocument(title: "Test")
        // 6 Mo > MAX_JSON_BYTES (5 Mo)
        let huge = String(repeating: "x", count: 6 * 1024 * 1024)
        #expect(throws: ChaqaqError.self) {
            _ = try api.addBlock(docId: docId, blockContentJson: huge)
        }
    }
}
