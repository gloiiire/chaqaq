import Testing
@testable import LeafFeature

// The font catalogue reproduces Apple Books' picker, whose order was
// measured on device: Original, Athelas, Avenir Next, Canela, Charter,
// Georgia, Iowan… — a flat alphabetical sort after the inherited entry.
//
// The list used to be grouped serif / sans-serif / monospace while its
// own comment claimed it was alphabetised. Nothing caught the
// contradiction because nothing asserted the order. These tests are
// that assertion.

@MainActor
@Suite("Reader font catalogue — flat alphabetical, System pinned")
struct ReaderFontCatalogueTests {

    /// "System" means "inherit the theme's font", so it is not a font
    /// name and must not sort with them — Books shows it first, labelled
    /// "Original".
    @Test func systemIsPinnedFirst() {
        #expect(ReaderThemeCustomizationSheet.bundledFonts.first == "System")
    }

    /// The regression guard: everything after "System" is sorted, with
    /// no category grouping reintroduced.
    @Test func remainingFamiliesAreAlphabetical() {
        let families = Array(ReaderThemeCustomizationSheet.bundledFonts.dropFirst())
        #expect(families == families.sorted(),
                "font list drifted out of alphabetical order: \(families)")
    }

    /// A duplicate would render two identical rows, both able to show the
    /// checkmark since selection is matched by name.
    @Test func familiesAreUnique() {
        let all = ReaderThemeCustomizationSheet.bundledFonts
        #expect(Set(all).count == all.count)
    }

    /// The families Books itself offers are the ones the parity work is
    /// judged against, so their absence would be a silent gap.
    @Test func coversTheFamiliesBooksOffers() {
        let all = ReaderThemeCustomizationSheet.bundledFonts
        for expected in ["Athelas", "Avenir Next", "Charter", "Georgia",
                         "Iowan Old Style", "Palatino", "Times New Roman"] {
            #expect(all.contains(expected), "missing \(expected)")
        }
    }

    /// Both bundled faces ship as `.ttc` under names that differ from
    /// their PostScript names; dropping either would strand a theme
    /// whose `fontFamily` points at it.
    @Test func includesTheBundledFaces() {
        let all = ReaderThemeCustomizationSheet.bundledFonts
        #expect(all.contains("Canela Text"))
        #expect(all.contains("Publico Text"))
    }
}
