import Testing
import Foundation
@testable import Pinkha

@MainActor
@Suite("DatabaseViewModel — integration via real FFI")
struct DatabaseViewModelTests {

    // ── Fixture helpers ───────────────────────────────────────────────────────

    private func makeVM() throws -> (DatabaseViewModel, URL) {
        let tmp  = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_dbvm_\(UUID().uuidString).db")
        let api  = try PinkhaApi(dbPath: tmp.path)
        let dbId = try api.createDatabase(title: "Test DB")
        let vm   = DatabaseViewModel(dbId: dbId, api: api)
        return (vm, tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    @Test func loadPopulatesTitleAndEmptyState() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        #expect(vm.titlePlain == "Test DB")
        #expect(vm.properties.isEmpty)
        #expect(vm.entries.isEmpty)
    }

    @Test func addEntryAppendsToLocalList() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addEntry()
        #expect(vm.entries.count == 1)
        #expect(!vm.entries[0].id.isEmpty)
    }

    @Test func addEntryPersistsAcrossLoad() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addEntry()
        vm.load()
        #expect(vm.entries.count == 1)
    }

    @Test func deleteEntryRemovesFromLocalList() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addEntry()
        let entryId = vm.entries[0].id
        vm.deleteEntry(id: entryId)
        #expect(vm.entries.isEmpty)
    }

    @Test func deleteEntryPersistsAcrossLoad() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addEntry()
        let entryId = vm.entries[0].id
        vm.deleteEntry(id: entryId)
        vm.load()
        #expect(vm.entries.isEmpty)
    }

    @Test func addPropertyAppendsColumnLocally() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Notes", type: .text)
        #expect(vm.properties.count == 1)
        #expect(vm.properties[0].name == "Notes")
        #expect(vm.properties[0].propertyType == .text)
    }

    @Test func addPropertyPersistsAcrossLoad() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Status", type: .text)
        vm.load()
        #expect(vm.properties.count == 1)
        #expect(vm.properties[0].name == "Status")
    }

    @Test func updateCellPersistsTextValue() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Name", type: .text)
        vm.addEntry()
        let entryId  = vm.entries[0].id
        let propId   = vm.properties[0].id
        vm.updateCell(entryId: entryId, propertyId: propId, value: .text("Hello"))
        vm.load()
        #expect(vm.entries[0].values[propId] == .text("Hello"))
    }

    @Test func updateCellPersistsCheckboxValue() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Done", type: .checkbox)
        vm.addEntry()
        let entryId = vm.entries[0].id
        let propId  = vm.properties[0].id
        vm.updateCell(entryId: entryId, propertyId: propId, value: .checkbox(true))
        vm.load()
        #expect(vm.entries[0].values[propId] == .checkbox(true))
    }

    @Test func deletePropertyRemovesFromLocalList() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Col", type: .text)
        let propId = vm.properties[0].id
        vm.deleteProperty(id: propId)
        #expect(vm.properties.isEmpty)
    }

    @Test func noErrorMessageAfterSuccessfulOperations() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "X", type: .text)
        vm.addEntry()
        vm.updateCell(entryId: vm.entries[0].id, propertyId: vm.properties[0].id, value: .text("ok"))
        #expect(vm.errorMessage == nil)
    }
}
