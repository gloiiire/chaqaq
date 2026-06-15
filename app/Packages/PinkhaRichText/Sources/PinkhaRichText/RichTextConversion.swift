import UIKit
import PinkhaFFI

// ── Conversion Span ↔ NSAttributedString ─────────────────────────────────────

/// Converts an array of `InlineTextFfi` spans into an `NSAttributedString` using `police` as the base font.
///
/// Default foreground precedence : inline `.color(...)` on the span
/// (set inside the loop) wins over `blockColor`, which wins over
/// `themeForeground`, which wins over the system `.label`. Inline
/// color is *not* persisted as `.pinkhaColor` on spans that only
/// inherit a higher tier, so removing the inline color naturally
/// falls back to whichever default applies at the next render.
public func spansToAttributed(
    _ spans: [InlineTextFfi],
    police: UIFont,
    blockColor: String? = nil,
    themeForeground: UIColor? = nil
) -> NSAttributedString {
    guard !spans.isEmpty else { return NSAttributedString() }
    let defaultForeground: UIColor = blockColor.map(uiColorFromName)
        ?? themeForeground
        ?? .label
    let result = NSMutableAttributedString()
    for span in spans {
        var isBold   = false
        var isItalic = false
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: defaultForeground]
        for style in span.styles {
            switch style {
            case .bold:              isBold = true
            case .italic:            isItalic = true
            case .underline:         attrs[.underlineStyle]      = NSUnderlineStyle.single.rawValue
            case .strikethrough:     attrs[.strikethroughStyle]  = NSUnderlineStyle.single.rawValue
            case .color(let nom):    attrs[.foregroundColor] = uiColorFromName(nom); attrs[.pinkhaColor] = nom
            case .link(let url):     if let u = URL(string: url) { attrs[.link] = u }
            }
        }
        attrs[.font] = fontWithTraits(police, bold: isBold, italic: isItalic)
        if isBold   { attrs[.pinkhaBold]   = true }
        if isItalic {
            attrs[.pinkhaItalic] = true
            attrs[.pinkhaObliqueness] = 0.2
        }
        result.append(NSAttributedString(string: span.content, attributes: attrs))
    }
    return result
}

/// Converts an `NSAttributedString` into an array of `InlineTextFfi` spans.
/// Detects bold/italic via custom keys (`.pinkhaBold`/`.pinkhaItalic`) and
/// via font symbolic traits (relative to `police` to avoid confusing a heading already bold by design).
public func attributedToSpans(_ attrStr: NSAttributedString, police: UIFont) -> [InlineTextFfi] {
    guard !attrStr.string.isEmpty else { return [] }
    var spans: [InlineTextFfi] = []
    let traitsBase = police.fontDescriptor.symbolicTraits
    let baseIsBold = traitsBase.contains(.traitBold)
    let baseIsItalic = traitsBase.contains(.traitItalic)
    attrStr.enumerateAttributes(in: NSRange(location: 0, length: attrStr.length)) { attrs, range, _ in
        let text = (attrStr.string as NSString).substring(with: range)
        guard !text.isEmpty else { return }
        var styles: [InlineStyleFfi] = []
        let fontTraits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
        let boldCustom = (attrs[.pinkhaBold] as? Bool) == true
        let italicCustom = (attrs[.pinkhaItalic] as? Bool) == true
        let boldFromFont = fontTraits.contains(.traitBold) && !baseIsBold
        let italicFromFont = fontTraits.contains(.traitItalic) && !baseIsItalic
        let italicFromObliqueness = attrs[.pinkhaObliqueness] != nil && !baseIsItalic

        if boldCustom || boldFromFont { styles.append(.bold) }
        if italicCustom || italicFromFont || italicFromObliqueness { styles.append(.italic) }
        if (attrs[.underlineStyle]     as? Int) != nil { styles.append(.underline) }
        if (attrs[.strikethroughStyle] as? Int) != nil { styles.append(.strikethrough) }
        if let nom = attrs[.pinkhaColor] as? String    { styles.append(.color(nom)) }
        if let url = attrs[.link]        as? URL       { styles.append(.link(url.absoluteString)) }
        spans.append(InlineTextFfi(content: text, styles: styles))
    }
    return spans
}
