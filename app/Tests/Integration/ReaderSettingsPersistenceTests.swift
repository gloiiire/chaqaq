import Testing
import Foundation
import PinkhaFFI
@testable import LeafFeature

// The customize sheet writes every one of its controls into
// `LeafReaderSettings`, which travels to Rust as a single JSON blob.
// The unit tests cover the sheet's pure logic and the UI tests cover its
// rendering, but neither would notice a field that silently fails to
// survive the round-trip — a renamed CodingKey, or a value the Rust side
// drops. That gap is what this file covers.

@MainActor
@Suite("Reader settings — persistence through the FFI")
struct ReaderSettingsPersistenceTests {

    private func makeVM() throws -> (LeafViewModel, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_reader_\(UUID().uuidString).db")
        let api = try PinkhaApi(dbPath: tmp.path)
        let leafId = try api.createLeaf(title: "Reader")
        return (LeafViewModel(leafId: leafId, api: api), tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    /// A fresh leaf must open on Books' factory values, because the sheet
    /// shows them as the current state before the user touches anything.
    @Test func freshLeafCarriesTheFactoryDefaults() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()

        let s = vm.readerSettings
        #expect(s.lineSpacing == 1.4)
        #expect(s.letterSpacing == 0.0)
        #expect(s.wordSpacing == 0.0)
        #expect(s.marginScale == 0.0)
        #expect(s.bold == false)
        #expect(s.justify == false)
        #expect(s.customLayoutEnabled == false)
        #expect(s.fontFamily == nil)
        #expect(s.themeAppearance == "settings")
    }

    /// Every control on the sheet, set to a value distinct from its
    /// default, then read back after a reload. A field dropped in the
    /// JSON bridge shows up here as a value that reverted.
    @Test func everyControlSurvivesTheRoundTrip() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()

        var s = vm.readerSettings
        s.fontFamily = "Charter"
        s.bold = true
        s.lineSpacing = 1.85
        s.letterSpacing = 0.07
        s.wordSpacing = -0.04
        s.marginScale = 0.32
        s.justify = true
        s.customLayoutEnabled = true
        s.themeAppearance = "dark"
        vm.saveReaderSettings(s)

        vm.load()
        let r = vm.readerSettings
        #expect(r.fontFamily == "Charter")
        #expect(r.bold)
        #expect(r.lineSpacing == 1.85)
        #expect(r.letterSpacing == 0.07)
        #expect(r.wordSpacing == -0.04)
        #expect(r.marginScale == 0.32)
        #expect(r.justify)
        #expect(r.customLayoutEnabled)
        #expect(r.themeAppearance == "dark")
    }

    /// "Original" in the font picker means "inherit the theme", which the
    /// model stores as `nil` rather than the string "System". Persisting
    /// the literal would make the leaf request a font family that does
    /// not exist.
    @Test func choosingOriginalClearsTheFontFamily() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()

        var s = vm.readerSettings
        s.fontFamily = "Georgia"
        vm.saveReaderSettings(s)
        vm.load()
        #expect(vm.readerSettings.fontFamily == "Georgia")

        s = vm.readerSettings
        s.fontFamily = nil
        vm.saveReaderSettings(s)
        vm.load()
        #expect(vm.readerSettings.fontFamily == nil)
    }

    /// Settings are per-leaf: Books keeps a theme on the book you set it
    /// on. Bleeding into a sibling would silently restyle other leaves.
    @Test func settingsDoNotLeakToAnotherLeaf() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_reader_\(UUID().uuidString).db")
        defer { cleanup(tmp) }
        let api = try PinkhaApi(dbPath: tmp.path)
        let a = try api.createLeaf(title: "A")
        let b = try api.createLeaf(title: "B")

        let vmA = LeafViewModel(leafId: a, api: api)
        vmA.load()
        var s = vmA.readerSettings
        s.lineSpacing = 2.1
        s.bold = true
        vmA.saveReaderSettings(s)

        let vmB = LeafViewModel(leafId: b, api: api)
        vmB.load()
        #expect(vmB.readerSettings.lineSpacing == 1.4)
        #expect(vmB.readerSettings.bold == false)
    }

    /// The sliders' extremes are reachable values, not clamped away — the
    /// sheet lets the user drag all the way to either end.
    @Test func sliderExtremesPersistUnclamped() throws {
        let (vm, url) = try makeVM(); defer { cleanup(url) }
        vm.load()

        var s = vm.readerSettings
        s.lineSpacing = 0.8          // low end of the sheet's range
        s.letterSpacing = -0.05
        s.wordSpacing = 0.30
        s.marginScale = 0.6          // high end
        vm.saveReaderSettings(s)

        vm.load()
        let r = vm.readerSettings
        #expect(r.lineSpacing == 0.8)
        #expect(r.letterSpacing == -0.05)
        #expect(r.wordSpacing == 0.30)
        #expect(r.marginScale == 0.6)
    }
}
