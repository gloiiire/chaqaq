import Testing
import Foundation
import PinkhaFFI
@testable import Pinkha

// Integration tests for the document view model: real VM + real PinkhaApi
// with a temporary SQLite DB destroyed after each test.

@MainActor
@Suite("DocumentViewModel — main operations")
struct DocumentViewModelTests {

    private func makeVM() throws -> (DocumentViewModel, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_vm_\(UUID().uuidString).db")
        let api = try PinkhaApi(dbPath: tmp.path)
        let docId = try api.createDocument(title: "Test")
        return (DocumentViewModel(docId: docId, api: api), tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    @Test func loadPopulatesTitleAndEmptyBlocks() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        #expect(vm.title == "Test")
        #expect(vm.blocks.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    @Test func addBlockAppendsToList() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addBlock(type: .text)
        #expect(vm.blocks.count == 1)
        #expect(vm.autoFocusId != nil)
    }

    @Test func addBlockAfterIdInsertsAtRightPosition() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addBlock(type: .text)
        let firstId = vm.blocks[0].id
        vm.addBlock(type: .text)
        vm.addBlock(type: .text, afterId: firstId)
        #expect(vm.blocks.count == 3)
        #expect(vm.blocks[1].id != firstId)
        #expect(vm.blocks[0].id == firstId)
    }

    @Test func addBlockAllTypes() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        for type in NewBlockType.allCases {
            vm.addBlock(type: type)
        }
        #expect(vm.blocks.count == NewBlockType.allCases.count)
    }

    @Test func deleteBlockRemovesFromList() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addBlock(type: .text)
        let id = vm.blocks[0].id
        vm.deleteBlock(id: id)
        #expect(vm.blocks.isEmpty)
    }

    @Test func deleteBlocksBatch() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addBlock(type: .text)
        vm.addBlock(type: .text)
        vm.addBlock(type: .text)
        let ids = Set(vm.blocks.prefix(2).map(\.id))
        vm.deleteBlocks(ids: ids)
        #expect(vm.blocks.count == 1)
        #expect(!ids.contains(vm.blocks[0].id))
    }

    @Test func saveTitlePersists() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.title = "Renamed"
        vm.saveTitle()
        // Reload to confirm persistence.
        vm.load()
        #expect(vm.title == "Renamed")
    }

    @Test func saveCoverPersists() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.saveCover("cover.aurora")
        #expect(vm.cover == "cover.aurora")
        vm.load()
        #expect(vm.cover == "cover.aurora")
    }

    @Test func moveBlockReorders() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addBlock(type: .text)
        vm.addBlock(type: .text)
        vm.addBlock(type: .text)
        let originalOrder = vm.blocks.map(\.id)
        // Move the 1st to the 3rd position (offset 3 in SwiftUI .onMove semantics)
        vm.moveBlock(from: IndexSet(integer: 0), to: 3)
        let after = vm.blocks.map(\.id)
        #expect(after[0] == originalOrder[1])
        #expect(after[1] == originalOrder[2])
        #expect(after[2] == originalOrder[0])
    }

    @Test func isNavigatingFalseAtStart() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        #expect(!vm.isNavigating)
    }

    @Test func startStopNavigationRepeatTogglesFlag() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addBlock(type: .text)
        vm.startNavigationRepeat(from: vm.blocks[0].id, next: true)
        #expect(vm.isNavigating)
        vm.stopNavigationRepeat()
        #expect(!vm.isNavigating)
    }

    @Test func activeBlockIdMutable() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.activeBlockId = "abc"
        #expect(vm.activeBlockId == "abc")
        vm.activeBlockId = nil
        #expect(vm.activeBlockId == nil)
    }
}
