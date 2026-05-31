import Testing
import UIKit
@testable import Pinkha

@Suite("uiColorFromName — mapping nom de couleur → UIColor")
struct UIColorFromNameTests {

    @Test func mapsAllFrenchColors() {
        #expect(uiColorFromName("rouge")  == .systemRed)
        #expect(uiColorFromName("rose")   == .systemPink)
        #expect(uiColorFromName("orange") == .systemOrange)
        #expect(uiColorFromName("jaune")  == .systemYellow)
        #expect(uiColorFromName("vert")   == .systemGreen)
        #expect(uiColorFromName("cyan")   == .cyan)
        #expect(uiColorFromName("bleu")   == .systemBlue)
        #expect(uiColorFromName("violet") == .systemPurple)
        #expect(uiColorFromName("marron") == .brown)
        #expect(uiColorFromName("gris")   == .systemGray)
    }

    @Test func mapsEnglishAliases() {
        #expect(uiColorFromName("red")    == .systemRed)
        #expect(uiColorFromName("pink")   == .systemPink)
        #expect(uiColorFromName("yellow") == .systemYellow)
        #expect(uiColorFromName("green")  == .systemGreen)
        #expect(uiColorFromName("blue")   == .systemBlue)
        #expect(uiColorFromName("purple") == .systemPurple)
        #expect(uiColorFromName("brown")  == .brown)
        #expect(uiColorFromName("gray")   == .systemGray)
        #expect(uiColorFromName("mint")   == .cyan)
        #expect(uiColorFromName("menthe") == .cyan)
    }

    @Test func unknownColorFallsBackToLabel() {
        #expect(uiColorFromName("invisible") == .label)
        #expect(uiColorFromName("") == .label)
    }

    @Test func isCaseInsensitive() {
        #expect(uiColorFromName("ROUGE") == .systemRed)
        #expect(uiColorFromName("Bleu")  == .systemBlue)
    }
}

@Suite("fontWithTraits — gras + italique avec fallbacks")
struct FontWithTraitsTests {

    private let base = UIFont.systemFont(ofSize: 16)

    @Test func plainReturnsBaseFont() {
        let font = fontWithTraits(base, bold: false, italic: false)
        #expect(font.pointSize == base.pointSize)
    }

    @Test func boldHasBoldTrait() {
        let font = fontWithTraits(base, bold: true, italic: false)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test func italicHasItalicTrait() {
        let font = fontWithTraits(base, bold: false, italic: true)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }

    @Test func boldItalicHasBothTraits() {
        let font = fontWithTraits(base, bold: true, italic: true)
        let traits = font.fontDescriptor.symbolicTraits
        #expect(traits.contains(.traitBold))
        #expect(traits.contains(.traitItalic))
    }

    @Test func preservesPointSize() {
        let large = UIFont.systemFont(ofSize: 28)
        #expect(fontWithTraits(large, bold: true, italic: false).pointSize == 28)
    }
}

@Suite("Attribut custom pinkhaColor")
struct PinkhaColorAttributeTests {

    @Test func keyIsConsistentAcrossUses() {
        let key1 = NSAttributedString.Key.pinkhaColor
        let key2 = NSAttributedString.Key.pinkhaColor
        #expect(key1 == key2)
        #expect(key1.rawValue == "com.pinkha.color")
    }
}
