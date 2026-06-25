import Testing
import PinkhaComposer
@testable import LibraryFeature

// Unit tests for the context-aware enablement rules of the CreateBubble.
// We exercise the static helpers directly — instantiating the View would
// require a SwiftUI environment we can't easily fake here. The rules are
// pure functions of `Composer.CreationContext`, so a switch table is
// enough coverage.

@Suite("CreateBubble — context-aware enablement (PRO-57)")
struct CreateBubbleContextTests {

    // MARK: - Leaf : enabled in every context.

    @Test("Leaf enabled at library root")
    func leafEnabledAtRoot() {
        #expect(CreateBubble.isLeafEnabled(in: .root))
    }

    @Test("Leaf enabled inside a shelf")
    func leafEnabledInShelf() {
        #expect(CreateBubble.isLeafEnabled(in: .shelf(id: "any")))
    }

    @Test("Leaf enabled inside a leaf (page-in-page)")
    func leafEnabledInLeaf() {
        #expect(CreateBubble.isLeafEnabled(in: .leaf(id: "any")))
    }

    @Test("Leaf enabled inside a book (creates a row)")
    func leafEnabledInBook() {
        #expect(CreateBubble.isLeafEnabled(in: .book(id: "any")))
    }

    // MARK: - Book : disabled inside a leaf / book.

    @Test("Book enabled at root")
    func bookEnabledAtRoot() {
        #expect(CreateBubble.isBookEnabled(in: .root))
    }

    @Test("Book enabled inside a shelf")
    func bookEnabledInShelf() {
        #expect(CreateBubble.isBookEnabled(in: .shelf(id: "any")))
    }

    @Test("Book disabled inside a leaf")
    func bookDisabledInLeaf() {
        #expect(!CreateBubble.isBookEnabled(in: .leaf(id: "any")))
    }

    @Test("Book disabled inside a book")
    func bookDisabledInBook() {
        #expect(!CreateBubble.isBookEnabled(in: .book(id: "any")))
    }

    // MARK: - Shelf : disabled inside a leaf / book.

    @Test("Shelf enabled at root")
    func shelfEnabledAtRoot() {
        #expect(CreateBubble.isShelfEnabled(in: .root))
    }

    @Test("Shelf enabled inside a shelf (sub-shelf)")
    func shelfEnabledInShelf() {
        #expect(CreateBubble.isShelfEnabled(in: .shelf(id: "any")))
    }

    @Test("Shelf disabled inside a leaf")
    func shelfDisabledInLeaf() {
        #expect(!CreateBubble.isShelfEnabled(in: .leaf(id: "any")))
    }

    @Test("Shelf disabled inside a book")
    func shelfDisabledInBook() {
        #expect(!CreateBubble.isShelfEnabled(in: .book(id: "any")))
    }
}
