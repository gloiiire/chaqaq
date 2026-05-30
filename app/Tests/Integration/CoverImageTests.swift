import Testing
import Foundation
@testable import Chaqaq

@MainActor
@Suite("Cover image — sauvegarde et persistance via VM")
struct CoverImageTests {

    private func makeVM() throws -> (DocumentViewModel, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chaqaq_cover_\(UUID().uuidString).db")
        let api = try ChaqaqApi(dbPath: tmp.path)
        let docId = try api.createDocument(title: "Cover")
        return (DocumentViewModel(docId: docId, api: api), tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    @Test func saveCoverStringPersists() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.saveCover("cover.forest")
        #expect(vm.cover == "cover.forest")
        vm.load()
        #expect(vm.cover == "cover.forest")
    }

    @Test func saveCoverNilClearsIt() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.saveCover("cover.ocean")
        #expect(vm.cover == "cover.ocean")
        vm.saveCover(nil)
        #expect(vm.cover == nil)
        vm.load()
        #expect(vm.cover == nil)
    }

    @Test func saveCoverImageWritesFileAndUpdatesCover() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        // Petit PNG de test (1×1 transparent)
        let png = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ])
        vm.saveCoverImage(data: png, fileExtension: "png")
        #expect(vm.cover?.hasSuffix(".png") == true)
        #expect(vm.errorMessage == nil)
    }

    @Test func saveCoverImageWithDefaultJpgExtension() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0]) // entête JPEG, suffit pour le test
        vm.saveCoverImage(data: data)
        #expect(vm.cover?.hasSuffix(".jpg") == true)
    }
}
