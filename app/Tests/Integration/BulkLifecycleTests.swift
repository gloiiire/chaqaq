import Testing
import Foundation
import PinkhaFFI
@testable import Pinkha

// Bulk delete / restore / purge across the real FFI.
//
// These replaced a Swift loop that issued one FFI call *and* one full
// library reload per selected item. The behaviour that matters at this
// level is that a mixed selection round-trips correctly and that a stale
// id does not strand the rest of the batch.

@Suite("Bulk lifecycle — mixed selections over the FFI")
struct BulkLifecycleTests {

    private func makeApi() throws -> (PinkhaApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_bulk_\(UUID().uuidString).db")
        return (try PinkhaApi(dbPath: tmp.path), tmp)
    }

    @Test func deletesLeavesBooksAndShelvesInOneCall() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }

        let leafA = try api.createLeaf(title: "A")
        let leafB = try api.createLeaf(title: "B")
        let book  = try api.createBook(title: "Book")
        let shelf = try api.createShelf(name: "Shelf", parentId: nil)

        let out = try api.deleteItems(leafIds: [leafA, leafB],
                                      bookIds: [book],
                                      shelfIds: [shelf.id])
        #expect(out.affected == 4)
        #expect(out.skipped == 0)
        #expect(try api.listLeaves().isEmpty)
        #expect(try api.listBooks().isEmpty)
        #expect(try api.listShelves().isEmpty)
    }

    @Test func aStaleIdDoesNotStrandTheRestOfTheBatch() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }

        // The selection is captured before the confirmation dialog appears,
        // so an id can legitimately be gone by the time the user confirms.
        let alive = try api.createLeaf(title: "Alive")
        let ghost = UUID().uuidString

        let out = try api.deleteItems(leafIds: [ghost, alive], bookIds: [], shelfIds: [])
        #expect(out.affected == 1)
        #expect(out.skipped == 1)
        #expect(try api.listLeaves().isEmpty)
    }

    @Test func restoreBringsTheWholeSelectionBack() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }

        let leaf  = try api.createLeaf(title: "A")
        let book  = try api.createBook(title: "B")
        let shelf = try api.createShelf(name: "S", parentId: nil)
        _ = try api.deleteItems(leafIds: [leaf], bookIds: [book], shelfIds: [shelf.id])

        let out = try api.restoreItems(leafIds: [leaf], bookIds: [book], shelfIds: [shelf.id])
        #expect(out.affected == 3)
        #expect(try api.listLeaves().count == 1)
        #expect(try api.listBooks().count == 1)
        #expect(try api.listShelves().count == 1)
    }

    @Test func purgeIsPermanent() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }

        let leaf = try api.createLeaf(title: "A")
        _ = try api.deleteItems(leafIds: [leaf], bookIds: [], shelfIds: [])
        _ = try api.purgeItems(leafIds: [leaf], bookIds: [], shelfIds: [])

        // Restoring a purged id finds nothing — it is skipped, not resurrected.
        let out = try api.restoreItems(leafIds: [leaf], bookIds: [], shelfIds: [])
        #expect(out.affected == 0)
        #expect(out.skipped == 1)
    }

    @Test func aMalformedIdIsRejectedBeforeAnythingIsTouched() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }

        let leaf = try api.createLeaf(title: "Keep me")
        #expect(throws: (any Error).self) {
            _ = try api.deleteItems(leafIds: [leaf, "not-a-uuid"], bookIds: [], shelfIds: [])
        }
        // Validation happens up front, so the valid id in the batch survives.
        #expect(try api.listLeaves().count == 1)
    }

    @Test func emptySelectionIsANoOp() throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try api.createLeaf(title: "Untouched")
        let out = try api.deleteItems(leafIds: [], bookIds: [], shelfIds: [])
        #expect(out.affected == 0)
        #expect(try api.listLeaves().count == 1)
    }
}
