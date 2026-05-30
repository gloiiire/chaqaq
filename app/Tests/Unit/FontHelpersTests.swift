import Testing
import UIKit
@testable import Chaqaq

@Suite("italicFontWithWeight — italique avec poids contrôlé")
struct ItalicFontWithWeightTests {

    @Test func returnsItalicFont() {
        let font = italicFontWithWeight(17, weight: .medium)
        // Selon le contexte SF Pro, withSymbolicTraits peut échouer ; le fallback est
        // italicSystemFont(ofSize:) qui doit, lui, porter le trait italique.
        let traits = font.fontDescriptor.symbolicTraits
        #expect(traits.contains(.traitItalic))
    }

    @Test func preservesPointSize() {
        #expect(italicFontWithWeight(22, weight: .heavy).pointSize == 22)
        #expect(italicFontWithWeight(11, weight: .regular).pointSize == 11)
    }

    @Test func handlesAllWeights() {
        let weights: [UIFont.Weight] = [.ultraLight, .light, .regular, .medium, .semibold, .bold, .heavy]
        for w in weights {
            let f = italicFontWithWeight(16, weight: w)
            #expect(f.pointSize == 16)
        }
    }
}

@Suite("fontWithTraits — cas additionnels")
struct FontWithTraitsExtendedTests {

    @Test func boldBaseFontStaysBold() {
        let base = UIFont.boldSystemFont(ofSize: 18)
        let font = fontWithTraits(base, bold: false, italic: false)
        // Même avec bold: false, la base est déjà bold → le trait est conservé.
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test func italicBaseFontStaysItalic() {
        let base = UIFont.italicSystemFont(ofSize: 18)
        let font = fontWithTraits(base, bold: false, italic: false)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }

    @Test func explicitBoldOverridesPlainBase() {
        let base = UIFont.systemFont(ofSize: 18)
        let font = fontWithTraits(base, bold: true, italic: false)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(!font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }

    @Test func largeSizeWorks() {
        let large = UIFont.systemFont(ofSize: 72)
        let font = fontWithTraits(large, bold: true, italic: true)
        #expect(font.pointSize == 72)
    }
}
