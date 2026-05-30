import Testing
import Foundation
@testable import Chaqaq

// Vérifie que les styles inline (couleur, gras, etc.) survivent au round-trip
// VM → API → JSON → reload → VM. Régression-clé du rich text.

@MainActor
@Suite("Color & styles — persistance via VM")
struct ColorPersistenceTests {

    private func makeVM() throws -> (DocumentViewModel, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chaqaq_color_\(UUID().uuidString).db")
        let api = try ChaqaqApi(dbPath: tmp.path)
        let docId = try api.createDocument(title: "Color")
        return (DocumentViewModel(docId: docId, api: api), tmp)
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
            Issue.record("la couleur 'rouge' doit survivre au reload"); return
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

        let spans = [InlineTextFfi(content: "chaqaq", styles: [.link("https://chaqaq.app")])]
        vm.saveBlock(id: vm.blocks[0].id, spans: spans)

        vm.load()
        guard case .link(let url2) = vm.blocks[0].spans.first?.styles.first else {
            Issue.record("le lien doit survivre"); return
        }
        #expect(url2 == "https://chaqaq.app")
    }

    @Test func todoDoneSurvivesReload() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()
        vm.addBlock(type: .todo)
        // Toggle done puis save.
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
            Issue.record("le niveau du heading doit survivre")
        }
    }
}
