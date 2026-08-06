import Testing
import SwiftUI
@testable import PinkhaCore

// Picking Light or Dark in the reader's appearance menu did nothing on a
// leaf with no theme. `.original` returned a nil colour scheme, which
// means "impose nothing", so the leaf stayed on whatever the app was
// already showing.
//
// The five named themes were never affected — they carry their own
// palette — which is exactly why the bug survived: the control worked
// everywhere except on the default.

@Suite("Theme colour scheme — the reader appearance is honoured")
struct ThemeColorSchemeTests {

    /// The regression itself.
    @Test func originalFollowsTheReaderAppearance() {
        #expect(AppSettings.Theme.original.effectiveColorScheme(darkVariant: true) == .dark)
        #expect(AppSettings.Theme.original.effectiveColorScheme(darkVariant: false) == .light)
    }

    /// `.original` must never return nil: nil is what let the choice be
    /// silently dropped.
    @Test func originalNeverImposesNothing() {
        for dark in [true, false] {
            #expect(AppSettings.Theme.original.effectiveColorScheme(darkVariant: dark) != nil)
        }
    }

    /// Themes that own a dark palette switch to it, as before.
    @Test func themesWithADarkPaletteStillSwitch() {
        for theme in AppSettings.Theme.allCases where theme.hasDarkVariant {
            #expect(theme.effectiveColorScheme(darkVariant: true) == .dark)
        }
    }

    /// Tranquille is dark by construction and has no light variant, so a
    /// light request must not lighten it — that would strand its text
    /// colour on a background it was never designed for.
    @Test func tranquilleStaysDarkEvenWhenLightIsRequested() {
        #expect(AppSettings.Theme.tranquille.effectiveColorScheme(darkVariant: false) == .dark)
    }

    /// The paper-like themes stay light for the same reason, mirrored.
    @Test func lightThemesStayLight() {
        for theme in [AppSettings.Theme.papier, .gras, .calme, .attention] {
            #expect(theme.effectiveColorScheme(darkVariant: false) == .light)
        }
    }

    /// `hasDarkVariant` marks themes with a palette of their own. It must
    /// stay false for `.original`, which borrows the app's — flipping it
    /// would make the tile advertise a distinct dark variant and would
    /// pull in the unused pure-black `darkBackgroundColor`.
    @Test func originalDoesNotClaimItsOwnDarkPalette() {
        #expect(AppSettings.Theme.original.hasDarkVariant == false)
    }
}
