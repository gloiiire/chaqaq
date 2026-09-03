import Testing
import Foundation
@testable import Pinkha
import PinkhaComposer

// The tab bar had no test coverage at all before the search-tab change.
// These lock the small amount of pure state behind it.

@MainActor
@Suite("Composer — tab selection")
struct ComposerTabSelectionTests {

    @Test func defaultsToTheLibraryTab() {
        #expect(Composer().selectedTab == .leaves)
    }

    @Test func everyTabKindRoundTripsThroughItsRawValue() {
        // `rawValue` is the Codable surface: a rename would silently break
        // any persisted selection, so pin the strings here.
        for kind in [Composer.TabKind.leaves, .books, .inbox, .search] {
            #expect(Composer.TabKind(rawValue: kind.rawValue) == kind)
        }
        #expect(Composer.TabKind.search.rawValue == "search")
        #expect(Composer.TabKind.leaves.rawValue == "leaves")
    }

    @Test func selectingTheSearchTabIsRepresentable() {
        // `.searchTabSelection` makes UIKit write this value on tab
        // activation and write the *previous* one back on cancel, so both
        // transitions have to round-trip through the model.
        let composer = Composer()
        composer.selectedTab = .books
        composer.selectedTab = .search
        #expect(composer.selectedTab == .search)
        composer.selectedTab = .books
        #expect(composer.selectedTab == .books)
    }
}
