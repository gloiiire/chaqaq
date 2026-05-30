import Testing
import Foundation
@testable import Chaqaq

@MainActor
@Suite("DocumentViewModel — gestion d'erreurs")
struct VMErrorHandlingTests {

    private func makeApi() throws -> (ChaqaqApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chaqaq_vm_err_\(UUID().uuidString).db")
        return (try ChaqaqApi(dbPath: tmp.path), tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    @Test func loadOfDeletedDocumentCapturesError() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        let docId = try api.createDocument(title: "À supprimer")
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
        // load échoue → errorMessage non nil
        vm.load()
        let firstError = vm.errorMessage
        #expect(firstError != nil)

        // tentative de save d'un bloc fantôme → autre erreur
        vm.errorMessage = nil
        let phantom = EditableBlock(id: UUID().uuidString, content: .text([]),
                                     spans: [], done: false)
        vm.saveBlock(phantom)
        #expect(vm.errorMessage != nil)
    }
}

@Suite("ChaqaqError — chemins LocalizedError")
struct ChaqaqErrorLocalizedTests {

    @Test func notFoundHasErrorDescription() {
        let err = ChaqaqError.NotFound(id: "abc")
        #expect(err.errorDescription != nil)
    }

    @Test func invalidOperationHasErrorDescription() {
        let err = ChaqaqError.InvalidOperation(detail: "x")
        #expect(err.errorDescription != nil)
    }

    @Test func storageHasErrorDescription() {
        let err = ChaqaqError.Storage(detail: "io")
        #expect(err.errorDescription != nil)
    }
}
