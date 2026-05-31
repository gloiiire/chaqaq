import Testing
@testable import Pinkha

@Suite("markdownShortcut — Notion shortcut conversion")
struct MarkdownShortcutTests {

    @Test func hashSpaceProducesHeading1() {
        guard case .heading(let level, let text) = markdownShortcut(for: "# ") else {
            Issue.record("expected .heading"); return
        }
        #expect(level == 1)
        #expect(text.isEmpty)
    }

    @Test func doubleHashProducesHeading2() {
        guard case .heading(let level, _) = markdownShortcut(for: "## ") else {
            Issue.record("expected .heading"); return
        }
        #expect(level == 2)
    }

    @Test func tripleHashProducesHeading3() {
        guard case .heading(let level, _) = markdownShortcut(for: "### ") else {
            Issue.record("expected .heading"); return
        }
        #expect(level == 3)
    }

    @Test func greaterThanSpaceProducesQuote() {
        guard case .quote(let icon, _) = markdownShortcut(for: "> ") else {
            Issue.record("expected .quote"); return
        }
        #expect(icon.isEmpty)
    }

    @Test func doubleBangProducesCalloutWithEmoji() {
        guard case .quote(let icon, _) = markdownShortcut(for: "!! ") else {
            Issue.record("expected .quote"); return
        }
        #expect(icon == "💡")
    }

    @Test func bracketsProduceTodo() {
        guard case .todo(let done, _) = markdownShortcut(for: "[ ] ") else {
            Issue.record("expected .todo"); return
        }
        #expect(!done)
    }

    @Test func bracketsAlternateFormProduceTodo() {
        #expect(markdownShortcut(for: "[] ") != nil)
        guard case .todo(let done, _) = markdownShortcut(for: "[] ") else {
            Issue.record("expected .todo"); return
        }
        #expect(!done)
    }

    @Test func tripleDashProducesDivider() {
        guard case .divider = markdownShortcut(for: "---") else {
            Issue.record("expected .divider"); return
        }
    }

    @Test func emptyStringIsNotAShortcut() {
        #expect(markdownShortcut(for: "") == nil)
    }

    @Test func regularTextIsNotAShortcut() {
        #expect(markdownShortcut(for: "Bonjour") == nil)
        #expect(markdownShortcut(for: "##") == nil) // missing trailing space
        #expect(markdownShortcut(for: "[ ]") == nil) // missing trailing space
    }

    @Test func hashWithoutSpaceIsNotShortcut() {
        #expect(markdownShortcut(for: "#") == nil)
    }
}
