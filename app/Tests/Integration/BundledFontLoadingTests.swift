import Testing
import UIKit
@testable import PinkhaCore

// A font family that fails to register does not raise anything: UIKit
// hands back a system serif and the theme quietly looks generic. The
// candidate chains are built to fall back on purpose, so a broken bundle
// is indistinguishable from a working one unless something asserts that
// the intended face is the one that actually resolved.
//
// This is the check that a wrong Info.plist entry, a missing build-phase
// resource, or a PostScript name typo would fail.

@Suite("Bundled fonts — the SIL OFL faces really register")
struct BundledFontLoadingTests {

    /// A static instance's PostScript name differs from its family name,
    /// and iOS accepts either depending on the version — so both spellings
    /// must resolve.
    @Test func bothSpellingsResolveForEveryBundledFace() {
        let names = [
            "Newsreader", "NewsreaderRoman-Regular",
            "NewsreaderRoman-Bold", "NewsreaderItalic-Italic",
            "Playfair Display", "PlayfairDisplayRoman-Regular",
            "PlayfairDisplayRoman-Bold", "PlayfairDisplayItalic-Italic",
        ]
        for name in names {
            #expect(UIFont(name: name, size: 17) != nil,
                    "\(name) did not register — check UIAppFonts and the build phase")
        }
    }

    /// The themes must land on their own face, not on the fallback further
    /// down the chain. Comparing family names catches exactly the silent
    /// degradation the chains would otherwise hide.
    @Test func themesResolveToTheirIntendedFamily() {
        #expect(AppSettings.Theme.tranquille.uiFont(size: 17).familyName == "Newsreader")
        #expect(AppSettings.Theme.calme.uiFont(size: 17).familyName == "Playfair Display")
    }

    /// Commercial Type's faces must be gone. If one still resolves, a
    /// leftover copy is installed somewhere and a build could pick it up.
    @Test func theNonRedistributableFacesAreAbsent() {
        for name in ["CanelaText-Regular", "PublicoText-Roman"] {
            #expect(UIFont(name: name, size: 17) == nil,
                    "\(name) still resolves — it must not ship")
        }
    }

    /// Bold and italic have to come from the bundled faces rather than
    /// from UIKit synthesising a slant, which looks visibly wrong on a
    /// high-contrast serif.
    @Test func boldAndItalicAreRealFacesNotSynthesised() {
        for family in ["Newsreader", "Playfair Display"] {
            let faces = UIFont.fontNames(forFamilyName: family)
            #expect(faces.count >= 4,
                    "\(family) exposes \(faces.count) faces, expected regular/italic/bold/bold-italic")
        }
    }
}
