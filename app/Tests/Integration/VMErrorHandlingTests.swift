import Testing
import Foundation
@testable import Pinkha

@MainActor
@Suite("DocumentViewModel — error handling")
struct VMErrorHandlingTests {

    private func makeApi() throws -> (PinkhaApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_vm_err_\(UUID().uuidString).db")
        return (try PinkhaApi(dbPath: tmp.path), tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    @Test func loadOfDeletedDocumentCapturesError() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let docId = try api.createDocument(title: "To delete")
        try api.deleteDocument(id: docId)

        let vm = DocumentViewModel(docId: docId, api: api)
        vm.load()
        #expect(vm.errorMessage != nil)
    }

    @Test func loadOfRandomUuidCapturesError() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let vm = DocumentViewModel(docId: UUID().uuidString, api: api)
        vm.load()
        #expect(vm.errorMessage != nil)
    }

    @Test func saveBlockOfMissingDocumentCapturesError() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let docId = try api.createDocument(title: "Doc")
        try api.deleteDocument(id: docId)

        let vm = DocumentViewModel(docId: docId, api: api)
        // load fails → errorMessage non nil
        vm.load()
        let firstError = vm.errorMessage
        #expect(firstError != nil)

        // attempt to persist a phantom block → another error. `saveBlock`
        // is burst-based and silently ignores blocks without a snapshot,
        // so the structural-mutation path (`persistBlock`) is the one
        // that must surface the storage error.
        vm.errorMessage = nil
        let phantom = EditableBlock(id: UUID().uuidString, content: .text([]),
                                     spans: [], done: false)
        vm.persistBlock(phantom)
        #expect(vm.errorMessage != nil)
    }
}

@Suite("PinkhaError — LocalizedError paths")
struct PinkhaErrorLocalizedTests {

    @Test func notFoundHasErrorDescription() {
        let err = PinkhaError.NotFound(id: "abc")
        #expect(err.errorDescription != nil)
    }

    @Test func invalidOperationHasErrorDescription() {
        let err = PinkhaError.InvalidOperation(detail: "x")
        #expect(err.errorDescription != nil)
    }

    @Test func storageHasErrorDescription() {
        let err = PinkhaError.Storage(detail: "io")
        #expect(err.errorDescription != nil)
    }
}
