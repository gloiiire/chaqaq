import Testing
import Foundation
@testable import Pinkha

// Integration tests: validation at the FFI boundary (payload/UUID limits).

@Suite("FFI — boundary validation")
struct FFIBoundaryTests {

    private func makeApi() throws -> (PinkhaApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_test_\(UUID().uuidString).db")
        return (try PinkhaApi(dbPath: tmp.path), tmp)
    }

    @Test func invalidUuidRejectedAsInvalidOperation() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: PinkhaError.self) {
            _ = try api.getDocumentJson(id: "pas-un-uuid")
        }
    }

    @Test func oversizedTitleRejected() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }

        // 128 KB > MAX_STRING_BYTES (64 KB)
        let huge = String(repeating: "a", count: 128 * 1024)
        #expect(throws: PinkhaError.self) {
            _ = try api.createDocument(title: huge)
        }
    }

    @Test func oversizedJsonPayloadRejected() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }

        let docId = try api.createDocument(title: "Test")
        // 6 MB > MAX_JSON_BYTES (5 MB)
        let huge = String(repeating: "x", count: 6 * 1024 * 1024)
        #expect(throws: PinkhaError.self) {
            _ = try api.addBlock(docId: docId, blockContentJson: huge)
        }
    }
}
