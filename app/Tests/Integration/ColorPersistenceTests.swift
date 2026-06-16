import Testing
import Foundation
import PinkhaFFI
@testable import LeafFeature
@testable import Pinkha

// Verifies that inline styles (colour, bold, etc.) survive the round-trip
// VM → API → JSON → reload → VM. Key regression test for rich text.

@MainActor
@Suite("Color & styles — persistence via VM")
struct ColorPersistenceTests {

    private func makeVM() throws -> (LeafViewModel, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_color_\(UUID().uuidString).db")
        let api = try PinkhaApi(dbPath: tmp.path)
        let leafId = try api.createLeaf(title: "Color")
        return (LeafViewModel(leafId: leafId, api: api), tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    @Test func colorSpanPersistsThroughVM() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addBlock(type: .text)

        let colored = [InlineTextFfi(content: "Rouge", styles: [.color("rouge")])]
        vm.saveBlock(id: vm.blocks[0].id, spans: colored)

        vm.load()
        let span = vm.blocks[0].spans.first
        #expect(span?.content == "Rouge")
        guard case .color(let name) = span?.styles.first else {
            Issue.record("color 'rouge' must survive the reload"); return
        }
        #expect(name == "rouge")
    }

    @Test func boldItalicPersistTogether() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addBlock(type: .text)

        let spans = [InlineTextFfi(content: "x", styles: [.bold, .italic])]
        vm.saveBlock(id: vm.blocks[0].id, spans: spans)

        vm.load()
        let styles = vm.blocks[0].spans.first?.styles ?? []
        #expect(styles.contains(where: { if case .bold = $0 { true } else { false } }))
        #expect(styles.contains(where: { if case .italic = $0 { true } else { false } }))
    }

    @Test func mixedSpansPreserveOrder() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addBlock(type: .text)

        let spans = [
            InlineTextFfi(content: "Bon", styles: [.bold]),
            InlineTextFfi(content: "jour", styles: [])
        ]
        vm.saveBlock(id: vm.blocks[0].id, spans: spans)

        vm.load()
        let reloaded = vm.blocks[0].spans
        #expect(reloaded.count == 2)
        #expect(reloaded[0].content == "Bon")
        #expect(reloaded[1].content == "jour")
    }

    @Test func linkPersistsWithUrl() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addBlock(type: .text)

        let spans = [InlineTextFfi(content: "pinkha", styles: [.link("https://pinkha.app")])]
        vm.saveBlock(id: vm.blocks[0].id, spans: spans)

        vm.load()
        guard case .link(let url2) = vm.blocks[0].spans.first?.styles.first else {
            Issue.record("le lien doit survivre"); return
        }
        #expect(url2 == "https://pinkha.app")
    }

    @Test func todoDoneSurvivesReload() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addBlock(type: .todo)
        // Toggle done then save.
        var block = vm.blocks[0]
        block.done = true
        vm.saveBlock(block)
        vm.load()
        #expect(vm.blocks[0].done)
    }

    @Test func headingLevelSurvivesReload() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addBlock(type: .title2)
        let block = vm.blocks[0]
        if case .heading(let level, _) = block.content {
            #expect(level == 2)
        } else {
            Issue.record("expected heading level 2")
        }
        vm.load()
        if case .heading(let level, _) = vm.blocks[0].content {
            #expect(level == 2)
        } else {
            Issue.record("heading level must survive the reload")
        }
    }
}
