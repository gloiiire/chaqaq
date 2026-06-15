import SwiftUI
import UIKit
import PinkhaFFI
import PinkhaCore

/// Resolves the cursor + selection tint from the user prefs. UIKit
/// ties the caret colour to `tintColor` on UITextView (there's no
/// separate `insertionPointColor` like UITextField has on iOS 18+),
/// so this toggle paints BOTH the caret and the selection lozenge
/// AND every inline `.link` (the default `linkTextAttributes` uses
/// the tint). Default on : accent ; off : `.label` (dynamic — white
/// in dark mode, black in light) so links never become invisible
/// against the matching background — the earlier hard-coded `.white`
/// rendered links unreadable in light mode.
@MainActor
func resolvedSelectionTint(_ settings: AppSettings) -> UIColor {
    settings.cursorFollowsAccent ? UIColor(settings.accentColor) : .label
}

// ── Custom attribute keys ─────────────────────────────────────────────────────

extension NSAttributedString.Key {
    /// Stores the color name alongside `.foregroundColor` for a reliable round-trip
    /// between `NSAttributedString` and `[InlineTextFfi]`.
    static let pinkhaColor  = NSAttributedString.Key("com.pinkha.color")
    /// Marks a segment as explicitly bold (survives `typingAttributes` resets by UIKit).
    static let pinkhaBold   = NSAttributedString.Key("com.pinkha.bold")
    /// Marks a segment as explicitly italic.
    static let pinkhaItalic = NSAttributedString.Key("com.pinkha.italic")
    /// Obliqueness value stored alongside italic for fonts where `withSymbolicTraits` fails.
    static let pinkhaObliqueness = NSAttributedString.Key("NSObliqueness")
}

// ── Font utilities ────────────────────────────────────────────────────────────

/// Returns a font derived from `base` with the requested bold/italic traits.
/// Falls back to `boldSystemFont`/`italicSystemFont` when `withSymbolicTraits` returns `nil`
/// (SF Pro does not always propagate traits in certain iOS contexts).
func fontWithTraits(_ base: UIFont, bold: Bool, italic: Bool) -> UIFont {
    let size = base.pointSize
    let traitsBase = base.fontDescriptor.symbolicTraits
    let renduBold = bold || traitsBase.contains(.traitBold)
    let renduItalic = italic || traitsBase.contains(.traitItalic)
    switch (renduBold, renduItalic) {
    case (true, true):
        let desc = UIFont.boldSystemFont(ofSize: size).fontDescriptor
        if let d = desc.withSymbolicTraits([.traitBold, .traitItalic]) { return UIFont(descriptor: d, size: size) }
        return UIFont.boldSystemFont(ofSize: size)
    case (true, false):  return UIFont.boldSystemFont(ofSize: size)
    case (false, true):  return UIFont.italicSystemFont(ofSize: size)
    case (false, false): return base
    }
}

/// Returns an italic font at the given size and weight.
/// `.italicSystemFont` is always regular, so this helper applies the italic trait
/// to a weighted font descriptor when possible.
func italicFontWithWeight(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
    let base = UIFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
        return UIFont(descriptor: d, size: size)
    }
    return .italicSystemFont(ofSize: size)
}

/// Converts a color name (French or English) to a `UIColor`.
/// Unknown names fall back to `.label` so the text remains readable.
func uiColorFromName(_ nom: String) -> UIColor {
    switch nom.lowercased() {
    case "rouge", "red":             return .systemRed
    case "rose", "pink":             return .systemPink
    case "orange":                   return .systemOrange
    case "jaune", "yellow":          return .systemYellow
    case "vert", "green":            return .systemGreen
    case "cyan", "menthe", "mint":   return .cyan
    case "bleu", "blue":             return .systemBlue
    case "violet", "purple":         return .systemPurple
    case "marron", "brown":          return .brown
    case "gris", "gray":             return .systemGray
    default:                         return .label
    }
}
