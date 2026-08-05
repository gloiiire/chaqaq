import Testing
import Foundation
import PinkhaFFI
@testable import BookFeature
@testable import Pinkha

@MainActor
@Suite("BookViewModel — integration via real FFI")
struct BookViewModelTests {

    // ── Fixture helpers ───────────────────────────────────────────────────────

    private func makeVM() throws -> (BookViewModel, URL) {
        let tmp  = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_dbvm_\(UUID().uuidString).db")
        let api  = try PinkhaApi(dbPath: tmp.path)
        let bookId = try api.createBook(title: "Test DB")
        let vm   = BookViewModel(bookId: bookId, api: api)
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
        // load() auto-creates the "Name" Title column on fresh books.
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

    // ── Entry + leaf linking ──────────────────────────────────────────────

    @Test func addEntryCreatesLinkedLeaf() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addEntry()
        #expect(vm.entries.count == 1)
        let leafId = vm.leafId(forEntryId: vm.entries[0].id)
        #expect(leafId != nil)
        #expect(!leafId!.isEmpty)
    }

    @Test func linkedLeafExistsInApi() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addEntry()
        let leafId = vm.leafId(forEntryId: vm.entries[0].id)!
        // The leaf must be loadable from the API.
        #expect(throws: Never.self) { _ = try vm.api.getLeafJson(id: leafId) }
    }

    @Test func addEntryPersistsLinkAcrossLoad() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addEntry()
        let entryId = vm.entries[0].id
        let leafId   = vm.leafId(forEntryId: entryId)
        vm.load()
        #expect(vm.entries.count == 1)
        #expect(vm.leafId(forEntryId: entryId) == leafId)
    }

    // ── Per-view sort config ──────────────────────────────────────────────
    //
    // Each view owns its own sort. `applySort` already writes to the active
    // view (a fix whose comment is still in the file); reading it back had
    // the same bug and did not get fixed with it.

    @Test func aViewsSortSurvivesReopeningTheBook() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Score", type: .number)
        vm.addView(type: .table)
        let tableId = vm.activeViewId!
        let scoreId = vm.properties.first { $0.name == "Score" }!.id

        vm.cycleSort(propertyId: scoreId)   // ascending
        vm.cycleSort(propertyId: scoreId)   // descending
        #expect(vm.activeSort?.propertyId == scoreId)
        #expect(vm.activeSort?.ascending == false)

        // Reopen: a fresh VM over the same database, Table still active.
        let fresh = BookViewModel(bookId: vm.bookId, api: vm.api)
        fresh.activeViewId = tableId
        fresh.load()
        #expect(fresh.activeViewId == tableId)
        #expect(fresh.activeSort?.propertyId == scoreId,
                "sort hydrated from the wrong view")
        #expect(fresh.activeSort?.ascending == false)
    }

    @Test func switchingViewsAdoptsTheTargetViewsSort() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Score", type: .number)
        let scoreId = vm.properties.first { $0.name == "Score" }!.id
        let listId = vm.activeViewId!

        vm.addView(type: .table)
        vm.cycleSort(propertyId: scoreId)
        #expect(vm.activeSort?.propertyId == scoreId)

        // Back to List, which was never sorted — it must not inherit
        // Table's sort just because the VM still holds it in memory.
        vm.activateView(id: listId)
        #expect(vm.activeSort == nil, "List inherited Table's sort")

        // …and returning to Table must bring its sort back.
        vm.activateView(id: vm.views.first { $0.id != listId }!.id)
        #expect(vm.activeSort?.propertyId == scoreId)
    }

    @Test func aBrandNewViewStartsUnsorted() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addProperty(name: "Score", type: .number)
        let scoreId = vm.properties.first { $0.name == "Score" }!.id
        vm.cycleSort(propertyId: scoreId)

        vm.addView(type: .gallery)
        #expect(vm.activeSort == nil,
                "a new view inherited the previous view's in-memory sort")
    }

    @Test func theTwoLeafIdLookupsAgree() throws {
        // The entry-based overload exists so views stop re-scanning all N
        // entries per row. It must answer identically to the id-based one,
        // otherwise the fast path silently changes behaviour.
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addEntry()
        vm.addEntry()
        for entry in vm.entries {
            #expect(vm.leafId(for: entry) == vm.leafId(forEntryId: entry.id))
            #expect(vm.leafId(for: entry) != nil)
        }
    }

    @Test func leafIdIsNilForAnEntryWithNoBackingLeaf() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addEntry()
        // An entry whose page-link cell was never filled — the tabular-row
        // case — must report no leaf rather than an empty string.
        var orphan = vm.entries[0]
        orphan.values.removeAll()
        #expect(vm.leafId(for: orphan) == nil)
    }

    @Test func deleteEntryAlsoDeletesLeaf() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addEntry()
        let entryId = vm.entries[0].id
        let leafId   = vm.leafId(forEntryId: entryId)!
        vm.deleteEntry(id: entryId)
        vm.load()
        #expect(vm.entries.isEmpty)
        // The linked leaf should be soft-deleted — API returns NotFound.
        #expect(throws: PinkhaError.self) { _ = try vm.api.getLeafJson(id: leafId) }
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
