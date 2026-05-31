import Testing
import UIKit
@testable import Pinkha

// Le round-trip spans ↔ NSAttributedString est le cœur du rich text :
// si un seul style se perd, l'utilisateur perd ses formatages.

@Suite("Spans ↔ NSAttributedString — round-trip")
struct AttributedRoundTripTests {

    private let font = UIFont.systemFont(ofSize: 17)

    @Test func emptySpansProducesEmptyString() {
        let attr = spansToAttributed([], police: font)
        #expect(attr.length == 0)
    }

    @Test func plainTextRoundTrips() {
        let spans = [InlineTextFfi(content: "Bonjour", styles: [])]
        let attr = spansToAttributed(spans, police: font)
        let back = attributedToSpans(attr, police: font)
        #expect(back.count == 1)
        #expect(back[0].content == "Bonjour")
        #expect(back[0].styles.isEmpty)
    }

    @Test func boldSurvivesRoundTrip() {
        let spans = [InlineTextFfi(content: "x", styles: [.bold])]
        let back = attributedToSpans(spansToAttributed(spans, police: font), police: font)
        #expect(back.first?.styles.contains(where: { if case .bold = $0 { true } else { false } }) == true)
    }

    @Test func italicSurvivesRoundTrip() {
        let spans = [InlineTextFfi(content: "x", styles: [.italic])]
        let back = attributedToSpans(spansToAttributed(spans, police: font), police: font)
        #expect(back.first?.styles.contains(where: { if case .italic = $0 { true } else { false } }) == true)
    }

    @Test func underlineSurvivesRoundTrip() {
        let spans = [InlineTextFfi(content: "x", styles: [.underline])]
        let back = attributedToSpans(spansToAttributed(spans, police: font), police: font)
        #expect(back.first?.styles.contains(where: { if case .underline = $0 { true } else { false } }) == true)
    }

    @Test func strikethroughSurvivesRoundTrip() {
        let spans = [InlineTextFfi(content: "x", styles: [.strikethrough])]
        let back = attributedToSpans(spansToAttributed(spans, police: font), police: font)
        #expect(back.first?.styles.contains(where: { if case .strikethrough = $0 { true } else { false } }) == true)
    }

    @Test func colorSurvivesRoundTripWithName() {
        let spans = [InlineTextFfi(content: "x", styles: [.color("rouge")])]
        let back = attributedToSpans(spansToAttributed(spans, police: font), police: font)
        if case .color(let name) = back.first?.styles.first {
            #expect(name == "rouge")
        } else {
            Issue.record("la couleur 'rouge' aurait dû survivre au round-trip")
        }
    }

    @Test func linkSurvivesRoundTrip() {
        let spans = [InlineTextFfi(content: "x", styles: [.link("https://pinkha.app")])]
        let back = attributedToSpans(spansToAttributed(spans, police: font), police: font)
        if case .link(let url) = back.first?.styles.first {
            #expect(url == "https://pinkha.app")
        } else {
            Issue.record("le lien aurait dû survivre")
        }
    }

    @Test func combinedBoldItalicRoundTrips() {
        let spans = [InlineTextFfi(content: "x", styles: [.bold, .italic])]
        let back = attributedToSpans(spansToAttributed(spans, police: font), police: font)
        let styles = Set(back.flatMap(\.styles).map(StyleKey.from))
        #expect(styles.contains(.bold))
        #expect(styles.contains(.italic))
    }
}

/// Réduit `InlineStyleFfi` à un identifiant Hashable simple pour les tests
/// (la version réelle n'est pas Hashable à cause des cases associées).
private enum StyleKey: Hashable {
    case bold, italic, underline, strikethrough, color(String), link(String)
    static func from(_ s: InlineStyleFfi) -> StyleKey {
        switch s {
        case .bold:           return .bold
        case .italic:         return .italic
        case .underline:      return .underline
        case .strikethrough:  return .strikethrough
        case .color(let n):   return .color(n)
        case .link(let u):    return .link(u)
        }
    }
}
