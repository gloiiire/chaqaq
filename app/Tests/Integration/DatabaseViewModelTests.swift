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

    // ── Load and title ────────────────────────────────────────────────────────

    @Test func loadPopulatesTitleAndEmptyState() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        #expect(vm.titlePlain == "Test DB")
        // load() auto-creates the "Name" Title column on fresh databases.
        #expect(vm.properties.count == 1)
        #expect(vm.properties[0].name == "Name")
        #expect(vm.entries.isEmpty)
    }

    @Test func loadCreatesHiddenPageProperty() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        #expect(vm.pagePropertyId != nil)
        // The page property must NOT appear in the visible properties list —
        // only the auto-created "Name" Title column is visible.
        #expect(vm.properties.allSatisfy { $0.name != "__pinkha_page__" })
        #expect(vm.properties.map(\.name) == ["Name"])
    }

    @Test func secondLoadReusesExistingPageProperty() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        let firstId = vm.pagePropertyId
        vm.load()
        #expect(vm.pagePropertyId == firstId)
    }

    // ── Entry + document linking ──────────────────────────────────────────────

    @Test func addEntryCreatesLinkedDocument() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addEntry()
        #expect(vm.entries.count == 1)
        let docId = vm.documentId(forEntryId: vm.entries[0].id)
        #expect(docId != nil)
        #expect(!docId!.isEmpty)
    }

    @Test func linkedDocumentExistsInApi() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addEntry()
        let docId = vm.documentId(forEntryId: vm.entries[0].id)!
        // The document must be loadable from the API.
        #expect(throws: Never.self) { _ = try vm.api.getDocumentJson(id: docId) }
    }

    @Test func addEntryPersistsLinkAcrossLoad() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addEntry()
        let entryId = vm.entries[0].id
        let docId   = vm.documentId(forEntryId: entryId)
        vm.load()
        #expect(vm.entries.count == 1)
        #expect(vm.documentId(forEntryId: entryId) == docId)
    }

    @Test func deleteEntryAlsoDeletesDocument() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addEntry()
        let entryId = vm.entries[0].id
        let docId   = vm.documentId(forEntryId: entryId)!
        vm.deleteEntry(id: entryId)
        vm.load()
        #expect(vm.entries.isEmpty)
        // The linked document should be soft-deleted — API returns NotFound.
        #expect(throws: PinkhaError.self) { _ = try vm.api.getDocumentJson(id: docId) }
    }

    // ── Properties and cells ──────────────────────────────────────────────────

    @Test func addPropertyAppendsVisibleColumn() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Status", type: .text)
        // The auto-created "Name" Title column sorts first; the new
        // column lands after it.
        #expect(vm.properties.count == 2)
        #expect(vm.properties.map(\.name) == ["Name", "Status"])
    }

    @Test func addPropertyPersistsAcrossLoad() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Priority", type: .text)
        vm.load()
        #expect(vm.properties.count == 2)
        #expect(vm.properties.map(\.name) == ["Name", "Priority"])
    }

    @Test func updateCellPersistsTextValue() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Notes", type: .text)
        vm.addEntry()
        let entryId = vm.entries[0].id
        let propId  = try #require(vm.properties.first { $0.name == "Notes" }).id
        vm.updateCell(entryId: entryId, propertyId: propId, value: .text("Done"))
        vm.load()
        #expect(vm.entries[0].values[propId] == .text("Done"))
    }

    @Test func updateCellPersistsCheckboxValue() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Checked", type: .checkbox)
        vm.addEntry()
        let entryId = vm.entries[0].id
        let propId  = try #require(vm.properties.first { $0.name == "Checked" }).id
        vm.updateCell(entryId: entryId, propertyId: propId, value: .checkbox(true))
        vm.load()
        #expect(vm.entries[0].values[propId] == .checkbox(true))
    }

    @Test func deletePropertyRemovesVisibleColumn() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Col", type: .text)
        let propId = try #require(vm.properties.first { $0.name == "Col" }).id
        vm.deleteProperty(id: propId)
        // Only the auto-created "Name" Title column survives.
        #expect(vm.properties.map(\.name) == ["Name"])
    }

    @Test func renamePropertyUpdatesNameInMemory() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Old Name", type: .text)
        let propId = vm.properties[0].id
        vm.renameProperty(id: propId, newName: "New Name")
        #expect(vm.properties[0].name == "New Name")
        #expect(vm.errorMessage == nil)
    }

    @Test func renamePropertyPersistsAcrossLoad() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Original", type: .text)
        let propId = vm.properties[0].id
        vm.renameProperty(id: propId, newName: "Renamed")
        vm.load()
        #expect(vm.properties.first(where: { $0.id == propId })?.name == "Renamed")
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
