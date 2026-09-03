import SwiftUI

// MARK: - Typography tokens
//
// Named `Font` tokens over Apple's text-style + design-family API. Every
// token maps to a `Font.TextStyle` under the hood so **Dynamic Type scales
// automatically**. Never expose a `Font.system(size:)` from a token — that
// breaks accessibility.
//
// Custom serif (leaf body) uses `.serif` design so we get SF Pro Serif
// with DT support out of the box, no custom font shipping needed. Mono
// design is reserved for code blocks. `.rounded` is available if we ever
// want a friendlier headline moment (WWDC25 push toward bolder headlines).

public extension Font {

    // MARK: Structural styles
    /// Largest title — welcome screens, empty-state hero copy.
    static let pinkhaLargeTitle: Font = .largeTitle.weight(.bold)
    /// Section-header display (e.g. `Good morning.` on the Library home).
    static let pinkhaTitle: Font = .title.weight(.bold)
    /// Sheet titles, book names.
    static let pinkhaTitle2: Font = .title2.weight(.semibold)
    /// Card titles, sub-section headers.
    static let pinkhaTitle3: Font = .title3.weight(.semibold)
    /// Bold body text — form labels, list row primary.
    static let pinkhaHeadline: Font = .headline
    /// Standard body copy.
    static let pinkhaBody: Font = .body
    /// Secondary body (subtitles under a title).
    static let pinkhaCallout: Font = .callout
    /// Metadata under a card (timestamps, tag counts).
    static let pinkhaFootnote: Font = .footnote
    /// Smallest metadata — section separators, hint chips.
    static let pinkhaCaption: Font = .caption

    // MARK: Reading styles (Leaf editor)
    /// Leaf body — SF Pro Serif at body size, best long-form reading feel.
    static let pinkhaLeafBody: Font = .system(.body, design: .serif)
    /// Leaf heading 1.
    static let pinkhaLeafH1: Font = .system(.title, design: .serif).weight(.bold)
    /// Leaf heading 2.
    static let pinkhaLeafH2: Font = .system(.title2, design: .serif).weight(.semibold)
    /// Leaf heading 3.
    static let pinkhaLeafH3: Font = .system(.title3, design: .serif).weight(.semibold)

    // MARK: Code
    /// Code block content — monospaced, DT-scaled at body size.
    static let pinkhaCode: Font = .system(.body, design: .monospaced)
    /// Inline code — footnote-scaled monospaced.
    static let pinkhaCodeInline: Font = .system(.footnote, design: .monospaced)

    // MARK: Section header (uppercase kerned label)
    /// Section-header style — matches the existing `SectionHeader` component.
    /// Section-header style. Aligns with the existing `SectionHeader`
    /// component (`.caption.weight(.semibold)` + kerning at the call site).
    /// Tighter than `.footnote` — matches the visual density that reads
    /// as an inline label rather than a paragraph heading.
    static let pinkhaSectionHeader: Font = .caption.weight(.semibold)
}
