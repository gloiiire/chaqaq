import Testing
import Foundation
@testable import Pinkha

@Suite("EditableBlock — in-memory editing model")
struct EditableBlockTests {

    @Test func plainTextConcatenatesAllSpans() {
        let block = EditableBlock(
            id: "x",
            content: .text([]),
            spans: [
                InlineTextFfi(content: "Bon", styles: []),
                InlineTextFfi(content: "jour", styles: [.bold])
            ],
            done: false
        )
        #expect(block.plainText == "Bonjour")
    }

    @Test func plainTextEmptyWhenNoSpans() {
        let block = EditableBlock(id: "x", content: .divider, spans: [], done: false)
        #expect(block.plainText == "")
    }

    @Test func idIsStable() {
        let block = EditableBlock(id: "abc", content: .text([]), spans: [], done: false)
        #expect(block.id == "abc")
    }
}

@Suite("BlockCallbacks — closure bundle")
struct BlockCallbacksTests {

    @Test func canBeConstructedWithMinimalCallbacks() {
        let cb = BlockCallbacks(
            onSave: {},
            onSaveSpans: { _ in },
            onDelete: {},
            onNewBlock: { _ in }
        )
        // Optional callbacks are nil by default.
        #expect(cb.onMerge == nil)
        #expect(cb.onNavigatePrevious == nil)
        #expect(cb.onNavigateNext == nil)
        #expect(cb.onStopNavigationRepeat == nil)
        #expect(cb.onLongPressSelection == nil)
        #expect(cb.onFocus == nil)
    }

    @Test func storesAllProvidedCallbacks() {
        var saveCalled = false
        let cb = BlockCallbacks(
            onSave: { saveCalled = true },
            onSaveSpans: { _ in },
            onDelete: {},
            onNewBlock: { _ in }
        )
        cb.onSave()
        #expect(saveCalled)
    }
}

@Suite("NewBlockType — toutes les variantes")
struct NewBlockTypeTests {

    @Test func allCasesHaveDisplayName() {
        for type in NewBlockType.allCases {
            #expect(!type.rawValue.isEmpty)
        }
    }

    @Test func idEqualsRawValue() {
        for type in NewBlockType.allCases {
            #expect(type.id == type.rawValue)
        }
    }

    @Test func enumHasExpectedCount() {
        // text, title1, title2, title3, quote, callout, todo, divider = 8
        #expect(NewBlockType.allCases.count == 8)
    }
}
