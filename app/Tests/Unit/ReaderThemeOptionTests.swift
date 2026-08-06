import Testing
import SwiftUI
@testable import LeafFeature
@testable import PinkhaCore

// The reader sheet's theme grid is derived from `AppSettings.Theme`,
// the same type that paints the leaf.
//
// It used to be a hand-written set living next to the `#Preview`, and
// production read from it. The two drifted, so the tiles advertised
// colours the reader never used — Papier cream in the picker, grey on
// the page. These tests exist to keep the one remaining source honest.

@MainActor
@Suite("Reader theme grid — derived from AppSettings.Theme")
struct ReaderThemeOptionTests {

    @Test func offersEveryThemeExactlyOnce() {
        let options = ReaderThemeOption.all
        #expect(options.count == AppSettings.Theme.allCases.count)
        // Identity is the persisted key, so duplicates would make two
        // tiles fight over the same selection highlight.
        #expect(Set(options.map(\.id)).count == options.count)
    }

    /// `Leaf.theme` stores `nil` for "no override" rather than the
    /// string "original". If the tile carried "original" instead, an
    /// untouched leaf would open the sheet with no tile highlighted.
    @Test func originalCarriesANilKey() {
        let original = ReaderThemeOption(theme: .original)
        #expect(original.key == nil)
        for theme in AppSettings.Theme.allCases where theme != .original {
            #expect(ReaderThemeOption(theme: theme).key == theme.rawValue)
        }
    }

    /// The regression this whole change is about: a tile must paint the
    /// colour the leaf will actually use.
    @Test func tileColoursMatchWhatTheLeafRenders() {
        for theme in AppSettings.Theme.allCases where theme != .original {
            let option = ReaderThemeOption(theme: theme)
            #expect(option.lightBackground == theme.backgroundColor,
                    "\(theme.rawValue): tile background differs from the leaf's")
            #expect(option.lightForeground == theme.foregroundColor,
                    "\(theme.rawValue): tile foreground differs from the leaf's")
        }
    }

    /// `.original` has no colours of its own — it follows the system,
    /// so the tile has to fall back to semantic colours rather than
    /// hardcode white, which would look wrong in dark mode.
    @Test func originalFallsBackToSemanticColours() {
        let original = ReaderThemeOption(theme: .original)
        #expect(original.lightBackground == Color(uiColor: .systemBackground))
        #expect(original.lightForeground == Color(uiColor: .label))
        #expect(original.hasDarkVariant == false)
    }

    /// The `*` marker on a tile promises a distinct dark variant, and
    /// the dark colours drive it.
    @Test func darkVariantsAgreeWithTheTheme() {
        for theme in AppSettings.Theme.allCases {
            let option = ReaderThemeOption(theme: theme)
            #expect(option.hasDarkVariant == theme.hasDarkVariant)
            if theme.hasDarkVariant {
                #expect(option.darkBackground == theme.darkBackgroundColor)
                #expect(option.darkForeground == theme.darkForegroundColor)
            }
        }
    }

    /// The tile renders its `Aa` in the theme's own typeface, so a
    /// mismatch here means the preview shows the wrong font.
    @Test func fontFamiliesComeFromTheTheme() {
        for theme in AppSettings.Theme.allCases {
            #expect(ReaderThemeOption(theme: theme).fontFamily == theme.fontFamily)
        }
        // Spot-check the mapping itself so a silent rename in
        // AppSettings would surface here rather than as a font that
        // quietly falls back to system.
        #expect(ReaderThemeOption(theme: .tranquille).fontFamily == "Publico")
        #expect(ReaderThemeOption(theme: .papier).fontFamily == "Charter")
        #expect(ReaderThemeOption(theme: .gras).fontFamily == nil)
    }

    /// Only Gras paints its body text bold, and the tile's `Aa` has to
    /// say so.
    @Test func boldPreviewFollowsTheTheme() {
        for theme in AppSettings.Theme.allCases {
            #expect(ReaderThemeOption(theme: theme).isPreviewBold == theme.boldText)
        }
        #expect(ReaderThemeOption(theme: .gras).isPreviewBold)
    }
}
