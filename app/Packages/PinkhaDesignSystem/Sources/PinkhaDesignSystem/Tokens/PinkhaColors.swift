#if canImport(UIKit)
import UIKit
#endif
import SwiftUI

// MARK: - Semantic color tokens
//
// Apple ships tiers, not palettes. This file exposes named aliases over the
// system's dynamic providers so features never touch raw `.systemBackground`
// or `.label` and gain High Contrast + Elevated variants for free.
//
// Two background families exist in HIG — **base** and **grouped**. Pick one
// per container. The `Surface` tokens map to base; the `Grouped` tokens map
// to grouped. Do not mix them within the same view hierarchy.
//
// Foreground uses `Color.primary/.secondary` (with implicit tertiary/quaternary
// on `Text` via opacity chains). Fills are for shape backgrounds (chips,
// avatars, tokens rendered *behind* content). Separators are hairline
// dividers.

public extension Color {

    // MARK: Foreground tiers
    /// Primary text and glyph. Maps to `UIColor.label`.
    static let pinkhaLabel: Color = .primary
    /// Secondary text (subtitles, timestamps). Maps to `UIColor.secondaryLabel`.
    static let pinkhaLabelSecondary: Color = .secondary
    /// Tertiary text (placeholders, muted metadata).
    static let pinkhaLabelTertiary: Color = Color(uiColor: .tertiaryLabel)
    /// Quaternary text (very muted separators between values).
    static let pinkhaLabelQuaternary: Color = Color(uiColor: .quaternaryLabel)

    // MARK: Surface (base family)
    /// Root screen background. Use for `LibraryView`, `LeafView`, top-level scenes.
    static let pinkhaSurface: Color = Color(uiColor: .systemBackground)
    /// One layer up — cards, callouts, elevated rows over `pinkhaSurface`.
    static let pinkhaSurfaceElevated: Color = Color(uiColor: .secondarySystemBackground)
    /// Nested layer — a card *inside* an elevated card.
    static let pinkhaSurfaceNested: Color = Color(uiColor: .tertiarySystemBackground)

    // MARK: Surface (grouped family — for grouped lists / settings)
    /// Grouped-list root background.
    static let pinkhaGrouped: Color = Color(uiColor: .systemGroupedBackground)
    /// Grouped-list row/section elevated background.
    static let pinkhaGroupedElevated: Color = Color(uiColor: .secondarySystemGroupedBackground)
    /// Grouped-list nested background.
    static let pinkhaGroupedNested: Color = Color(uiColor: .tertiarySystemGroupedBackground)

    // MARK: Fill tiers (shape backgrounds behind content)
    /// Primary fill — buttons, chips.
    static let pinkhaFill: Color = Color(uiColor: .systemFill)
    /// Secondary fill — pressed states, subtle backgrounds.
    static let pinkhaFillSecondary: Color = Color(uiColor: .secondarySystemFill)
    /// Tertiary fill — placeholders, disabled surfaces.
    static let pinkhaFillTertiary: Color = Color(uiColor: .tertiarySystemFill)
    /// Quaternary fill — very muted state indicators.
    static let pinkhaFillQuaternary: Color = Color(uiColor: .quaternarySystemFill)

    // MARK: Separators
    /// Hairline separator drawn *under* content — reads through material.
    static let pinkhaSeparator: Color = Color(uiColor: .separator)
    /// Opaque separator — full-alpha divider between opaque surfaces.
    static let pinkhaSeparatorOpaque: Color = Color(uiColor: .opaqueSeparator)
}
