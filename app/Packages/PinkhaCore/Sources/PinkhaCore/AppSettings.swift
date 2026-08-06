import SwiftUI
import UIKit

// MARK: - Reader-theme environment

/// SwiftUI environment key for the currently-active reader theme. Read
/// by every block row that builds a `UIFont` so they pick up the
/// theme's font family (Georgia / Charter / Palatino / Avenir Next /
/// system). Defaults to `.original` (= system font), so leaves without
/// a theme behave identically to before. Set from `LeafView` based on
/// `vm.theme`.
private struct ReaderThemeKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: AppSettings.Theme = .original
}

public extension EnvironmentValues {
    var readerTheme: AppSettings.Theme {
        get { self[ReaderThemeKey.self] }
        set { self[ReaderThemeKey.self] = newValue }
    }
}

/// Multiplier applied to every block row's body font size — drives the
/// A−/A+ stepper in the reader settings sheet. Defaults to `1.0`. The
/// helpers `Theme.uiFont(size:scale:)` and `font(size:scale:)` apply
/// this for consumers ; block rows compute their base point size and
/// pass the scale through.
private struct ReaderFontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    var readerFontScale: Double {
        get { self[ReaderFontScaleKey.self] }
        set { self[ReaderFontScaleKey.self] = newValue }
    }
}

/// PRO-62 typography bundle propagated through the leaf rendering
/// pipeline. Block rows read this to build their `NSAttributedString`
/// attributes (kerning, paragraph style, alignment, bold weight).
/// Defaults to factory values so leaves without overrides render
/// identically to before.
public struct ReaderTypographyOverrides: Equatable, Sendable {
    public var bold: Bool
    public var lineSpacingMultiple: Double   // 1.0 = single ; 1.4 = Apple default
    public var letterSpacing: Double         // em fraction
    public var wordSpacing: Double           // em fraction
    public var marginScale: Double           // 0.0 … 0.6 of leaf width
    public var justify: Bool
    public var customLayoutEnabled: Bool     // gates the 4 sliders
    /// PRO-62 : custom font family selected via the Personnaliser
    /// Police picker. `nil` falls back to the active theme's font.
    /// Carried in the env so every block row can pick it up without
    /// threading it through every BlockTextEditor call site.
    public var fontFamily: String?

    public init(
        bold: Bool = false,
        lineSpacingMultiple: Double = 1.4,
        letterSpacing: Double = 0.0,
        wordSpacing: Double = 0.0,
        marginScale: Double = 0.0,
        justify: Bool = false,
        customLayoutEnabled: Bool = false,
        fontFamily: String? = nil
    ) {
        self.bold = bold
        self.lineSpacingMultiple = lineSpacingMultiple
        self.letterSpacing = letterSpacing
        self.wordSpacing = wordSpacing
        self.marginScale = marginScale
        self.justify = justify
        self.customLayoutEnabled = customLayoutEnabled
        self.fontFamily = fontFamily
    }

    /// Resolves a `UIFont` for body text at the given size, applying
    /// the active typography overrides on top of the supplied theme.
    /// When `fontFamily` is set (user picked a custom font in the
    /// Personnaliser sheet), walks the bundled-font PostScript chains
    /// (Publico Text / Canela Text / Avenir Next / etc.) before
    /// defaulting to the theme's own font. The `bold` flag bumps the
    /// weight to `.bold` regardless of which family resolves.
    public func resolvedFont(theme: AppSettings.Theme, size: CGFloat) -> UIFont {
        let weight: UIFont.Weight = bold ? .bold : .regular
        guard let family = fontFamily else {
            return theme.uiFont(size: size, weight: weight)
        }
        // 1) Pre-known aliases (Publico / Canela / Proxima Nova ship
        //    under varied PostScript names — walk their candidate
        //    chains first).
        let primaryCandidates: [String]
        switch family {
        case "Publico", "Publico Text":
            primaryCandidates = AppSettings.Theme.publicoNameCandidates
        case "Canela", "Canela Text":
            primaryCandidates = AppSettings.Theme.canelaNameCandidates
        case "Proxima Nova":
            primaryCandidates = AppSettings.Theme.proximaNovaNameCandidates
        default:
            primaryCandidates = [family]
        }
        for name in primaryCandidates {
            if let f = UIFont(name: name, size: size) {
                let traits: [UIFontDescriptor.TraitKey: Any] = [.weight: weight.rawValue]
                let descriptor = f.fontDescriptor.addingAttributes([.traits: traits])
                return UIFont(descriptor: descriptor, size: size)
            }
        }
        // 2) Treat the input as a FAMILY name and ask UIKit to
        //    enumerate its PostScript faces — picks the regular face,
        //    then applies weight via descriptor. Handles every other
        //    iOS-bundled family the picker exposes (Avenir Next,
        //    Bodoni 72, Hoefler Text, Iowan Old Style …) generically.
        let faces = UIFont.fontNames(forFamilyName: family)
        if let postscriptName = faces.first,
           let f = UIFont(name: postscriptName, size: size) {
            let traits: [UIFontDescriptor.TraitKey: Any] = [.weight: weight.rawValue]
            let descriptor = f.fontDescriptor.addingAttributes([.traits: traits])
            return UIFont(descriptor: descriptor, size: size)
        }
        // 3) Last resort : system.
        return UIFont.systemFont(ofSize: size, weight: weight)
    }

    /// Builds `[NSAttributedString.Key: Any]` to pass into block rows'
    /// `BlockTextEditor.extraAttrs`. Justify is ALWAYS honoured (its
    /// own top-level toggle in the customize sheet, independent from
    /// the Personnaliser/accessibility section). The four spacing
    /// values + line-height only apply when `customLayoutEnabled` is
    /// true. Font weight + family are handled separately by
    /// `resolvedFont(theme:size:)` since they bake into the base font.
    public func attributedAttributes(baseFontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        // Short-circuit when there's nothing to add at all (no
        // justify, no overrides) — avoids allocating a paragraph
        // style for every block in the leaf.
        if !justify && !customLayoutEnabled { return [:] }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = justify ? .justified : .natural
        if customLayoutEnabled {
            paragraph.lineHeightMultiple = CGFloat(lineSpacingMultiple)
        }
        var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
        if customLayoutEnabled {
            if letterSpacing != 0 {
                attrs[.kern] = CGFloat(letterSpacing * baseFontSize)
            }
            if wordSpacing != 0 {
                attrs[.tracking] = CGFloat(wordSpacing * baseFontSize)
            }
        }
        return attrs
    }
}

private struct ReaderTypographyKey: EnvironmentKey {
    static let defaultValue: ReaderTypographyOverrides = .init()
}

public extension EnvironmentValues {
    var readerTypography: ReaderTypographyOverrides {
        get { self[ReaderTypographyKey.self] }
        set { self[ReaderTypographyKey.self] = newValue }
    }
}

extension Font.Weight {
    /// Bridge SwiftUI's font weight to the matching UIKit weight so
    /// `AppSettings.Theme.font(size:weight:)` can build a `UIFont`
    /// underneath and wrap it as a `Font`.
    var uiKitWeight: UIFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .regular:    return .regular
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .regular
        }
    }
}

/// User-facing preferences that affect the whole app. Persisted in
/// `UserDefaults` so they survive a relaunch — small enough that a real
/// data layer would be overkill.
///
/// Two settings today:
/// 1. `accentColorName` — drives `.tint(...)` at the root so every
///    standard SwiftUI affordance (selected tab icon, cursor, swipe
///    actions, NavigationLink chevron, etc.) recolors uniformly.
/// 2. `spotlightTinted` — when on, the search-hit spotlight paints a
///    soft accent tint behind the matched block in addition to blurring
///    the rest of the doc. Off by default; some users prefer the
///    cleaner blur-only look.
@MainActor
@Observable
public final class AppSettings {
    /// Catalogue of accent colors offered in the picker. Keeping the
    /// mapping name → Color in one place lets us persist a stable
    /// string in UserDefaults (Color isn't `Codable` cleanly) and round-
    /// trip it on relaunch.
    /// Books.app-style reading themes — bundles a background colour
    /// and a foreground colour, plus a "bold" flavour that switches
    /// the editor's base font to a heavy weight. Default `.original`
    /// keeps the iOS-native system background, so the rest of the
    /// app stays untouched until a user opts in.
    public enum Theme: String, CaseIterable, Identifiable {
        case original, tranquille, papier, gras, calme, attention

        public var id: String { rawValue }

        /// Localizable via `Localizable.xcstrings` — returning a
        /// `LocalizedStringKey` ensures `Text(theme.label)` picks the
        /// `LocalizedStringKey` initializer, not the verbatim-`String`
        /// one that bypasses the catalog.
        public var label: LocalizedStringKey {
            switch self {
            case .original:  return "Match App Appearance"
            case .tranquille: return "Tranquille"
            case .papier:    return "Papier"
            case .gras:      return "Gras"
            case .calme:     return "Calme"
            case .attention: return "Attention"
            }
        }

        /// Same content, already resolved through the string catalogue,
        /// for places where SwiftUI wants a `String` (text
        /// interpolation, attributed-string composition, etc.).
        public var labelString: String {
            switch self {
            case .original:   return String(localized: "Match App Appearance")
            case .tranquille: return String(localized: "Tranquille")
            case .papier:     return String(localized: "Papier")
            case .gras:       return String(localized: "Gras")
            case .calme:      return String(localized: "Calme")
            case .attention:  return String(localized: "Attention")
            }
        }

        /// `nil` = inherit the system background (`.original` does
        /// this so light/dark mode keeps working untouched).
        /// Background colour for the leaf body.
        ///
        /// Exact values, extracted from Apple Books rather than eyeballed:
        /// `BookEPUB.BookThemeEntity.backgroundColor` builds them as IEEE-754
        /// immediates, and emulating that getter's branch tree over
        /// (theme index, dark variant) yields the table below. Four of the six
        /// were previously off by enough to see — Tranquille most of all, at
        /// #1C1C1C against a real #4A4A4D. See
        /// `utilities/docs/BOOKS-READER-SETTINGS-RE.md` §10.3.
        ///
        /// `.original` returns nil: it means "no override, follow the system".
        public var backgroundColor: Color? {
            switch self {
            case .original:   return nil
            case .tranquille: return Color(hex: 0x4A4A4D)
            case .papier:     return Color(hex: 0xEEEDED)
            case .gras:       return Color(hex: 0xFFFFFF)
            case .calme:      return Color(hex: 0xF1E2C9)
            case .attention:  return Color(hex: 0xFFFCF4)
            }
        }

        /// Foreground colour for body text. `nil` falls back to `.label`.
        ///
        /// Only Calme is measured: Books builds its label colours through a
        /// dynamic `UIColor` whose trait-collection block dispatches via a
        /// function pointer, which static disassembly does not follow for
        /// reasonable effort. Calme was instead sampled from the live preview
        /// in a reference capture — that area renders the theme at full
        /// opacity, confirmed by its background matching the extracted value
        /// to within capture compression.
        ///
        /// The other five keep their previous approximations and are **not**
        /// verified against Apple.
        public var foregroundColor: Color? {
            switch self {
            case .original:   return nil
            case .tranquille: return Color(white: 0.88)          // non vérifié
            case .papier:     return Color.black                 // non vérifié
            case .gras:       return Color.black                 // non vérifié
            case .calme:      return Color(hex: 0x32281E)        // mesuré
            case .attention:  return Color(red: 0.18, green: 0.14, blue: 0.07) // non vérifié
            }
        }

        /// Forces a `ColorScheme` override on the theme's view tree
        /// so system controls (cursor, selection lozenge, etc.) match
        /// the theme background. `nil` = leave system / appearance
        /// alone. Only `.tranquille` is intrinsically dark — the
        /// other backgrounds are light.
        public var colorScheme: ColorScheme? {
            switch self {
            case .original:  return nil
            case .tranquille: return .dark
            case .papier, .gras, .calme, .attention: return .light
            }
        }

        /// Whether the theme paints body text with a bolder weight
        /// (Books.app's "Gras" flavour).
        public var boldText: Bool { self == .gras }

        /// True if this theme exposes a meaningfully different dark
        /// variant when the user flips the sun/moon toggle. Apple
        /// Books reserves Original (always light) and Tranquille
        /// (always dark) as fixed ; the others (Papier, Gras, Calme,
        /// Attention) swap.
        public var hasDarkVariant: Bool {
            switch self {
            case .original, .tranquille: return false
            case .papier, .gras, .calme, .attention: return true
            }
        }

        /// Background colour for the leaf rendering when the user has
        /// flipped the sun/moon toggle to dark. Falls back to the
        /// light value for themes that don't have a distinct dark
        /// variant. Mirrors the second-row palette in the theme grid.
        public var darkBackgroundColor: Color? {
            switch self {
            case .original:   return Color(hex: 0x000000)
            case .tranquille: return Color(hex: 0x000000)
            case .papier:     return Color(hex: 0x1C1C1E)
            case .gras:       return Color(hex: 0x000000)
            case .calme:      return Color(hex: 0x423B30)
            case .attention:  return Color(hex: 0x18160C)
            }
        }

        /// Dark-variant foreground. Same caveat as `foregroundColor`: only
        /// Calme is measured.
        public var darkForegroundColor: Color? {
            switch self {
            case .original:   return Color.white
            case .tranquille: return foregroundColor
            case .papier:     return Color(red: 0.85, green: 0.83, blue: 0.78) // non vérifié
            case .gras:       return Color.white
            case .calme:      return Color(hex: 0xF7EDDD)        // mesuré
            case .attention:  return Color(red: 0.95, green: 0.92, blue: 0.85) // non vérifié
            }
        }

        /// Effective background — picks the dark variant only when
        /// `darkVariant=true` AND the theme actually has one. Callers
        /// pass the sheet's `readerIsDarkVariant` here.
        public func effectiveBackgroundColor(darkVariant: Bool) -> Color? {
            (darkVariant && hasDarkVariant) ? darkBackgroundColor : backgroundColor
        }

        public func effectiveForegroundColor(darkVariant: Bool) -> Color? {
            (darkVariant && hasDarkVariant) ? darkForegroundColor : foregroundColor
        }

        /// Effective color-scheme override for system controls. Themes
        /// with a real dark variant flip to `.dark` when the toggle
        /// is on ; others keep their intrinsic scheme.
        public func effectiveColorScheme(darkVariant: Bool) -> ColorScheme? {
            // `.original` veut dire « la surface de l'app », qui existe
            // dans les DEUX apparences. Il doit donc suivre le choix
            // Clair/Sombre du lecteur comme n'importe quel autre thème.
            //
            // Il tombait avant sur `colorScheme`, qui vaut `nil` pour
            // `.original` : la leaf restait sur l'apparence de l'app et
            // choisir « Clair » sur un appareil sombre ne faisait
            // strictement rien. `hasDarkVariant` reste `false` pour lui
            // — ce drapeau sert à marquer les thèmes qui ont une
            // palette sombre PROPRE, et `.original` n'en a pas : il
            // emprunte celle de l'app.
            if self == .original { return darkVariant ? .dark : .light }
            if darkVariant && hasDarkVariant { return .dark }
            return colorScheme
        }

        /// Font family used by the theme — Apple-Books-exact mapping
        /// (corrected 2026-06-27 after user verification) :
        ///
        ///   • Original    → System (San Francisco)
        ///   • Tranquille  → Publico (Commercial Type serif bundled
        ///                   via PublicoText.ttc)
        ///   • Papier      → Charter (iOS-bundled)
        ///   • Gras        → System (San Francisco) + bold ON by default
        ///   • Calme       → Canela (Commercial Type serif bundled
        ///                   via CanelaText.ttc)
        ///   • Attention   → Times New Roman (iOS-bundled)
        ///
        /// Publico + Canela aren't exposed under those exact PostScript
        /// names on every iOS build — `uiFont(size:)` walks the
        /// per-theme name candidate chains below.
        public var fontFamily: String? {
            switch self {
            case .original:   return nil
            case .tranquille: return "Publico"
            case .papier:     return "Charter"
            case .gras:       return nil
            case .calme:      return "Canela"
            case .attention:  return "Proxima Nova"
            }
        }

        /// Human-readable name shown in the customize sheet's "Police"
        /// row when the user hasn't picked a custom font (defaults to
        /// the theme's font). Matches Apple Books labels exactly
        /// (user-verified 2026-06-27 — `.original` shows "Original",
        /// not the underlying SF name).
        public var fontDisplayName: String {
            switch self {
            case .original:   return "Original"
            case .tranquille: return "Publico Text"
            case .papier:     return "Charter"
            case .gras:       return "San Francisco"
            case .calme:      return "Canela Text"
            case .attention:  return "Proxima Nova"
            }
        }

        /// Apple-Books-exact line-spacing defaults per theme
        /// (verified 2026-06-27).
        public var defaultLineSpacing: Double {
            switch self {
            case .original:   return 1.40
            case .tranquille: return 1.40
            case .papier:     return 1.55
            case .gras:       return 1.50
            case .calme:      return 1.55
            case .attention:  return 1.40
            }
        }

        /// Whether the theme defaults to bold body text (Apple Books'
        /// Gras flavour).
        public var defaultBold: Bool { self == .gras }

        /// Apple-Books-exact justify default per theme — Tranquille
        /// and Attention ship with text justification ON.
        public var defaultJustify: Bool {
            switch self {
            case .tranquille, .attention: return true
            default: return false
            }
        }

        /// Whether the "Personnaliser" master toggle starts ON when
        /// the user selects this theme. Original is the only theme
        /// with no out-of-the-box typography overrides (user-verified
        /// 2026-06-27) — every other theme has at least one default
        /// (line spacing, bold, or justify) that requires the toggle.
        public var defaultCustomLayoutEnabled: Bool {
            self != .original
        }

        /// PostScript-name candidates for Tranquille (Publico Text).
        static let publicoNameCandidates = [
            "PublicoText-Roman", "Publico Text", "PublicoText",
            "Publico", "Publico-Text", "Publico-Regular",
            ".AppleSystemUIFontSerif",
            "HoeflerText-Regular", "Hoefler Text",
        ]

        /// PostScript-name candidates for Calme (Canela Text).
        static let canelaNameCandidates = [
            "CanelaText-Regular", "Canela Text", "CanelaText",
            "Canela-Regular", "Canela",
            "Palatino-Roman", "Palatino",   // editorial-serif fallback
        ]

        /// PostScript-name candidates for Attention (Proxima Nova).
        /// Proxima Nova is Mark Simonson Studio's commercial geometric
        /// sans — not iOS-bundled. Fallback to Avenir Next, the
        /// closest iOS-bundled cousin (both are humanist-geometric
        /// hybrids designed in the same era).
        static let proximaNovaNameCandidates = [
            "ProximaNova-Regular", "Proxima Nova", "ProximaNova",
            "AvenirNext-Regular", "Avenir Next",
        ]

        /// No italic-by-default for any preset in the Apple mapping
        /// — kept for backward compat but always returns false now.
        public var isPreviewItalic: Bool { false }

        /// Builds a `UIFont` for this theme at the given point size,
        /// applying the bold variant when relevant. Resolves Publico
        /// (Tranquille) through `publicoNameCandidates` since iOS
        /// exposes it under different PostScript names depending on
        /// installed system bundles. Falls back to system when the
        /// named family isn't available on device.
        public func uiFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
            let effective: UIFont.Weight = boldText ? .bold : weight
            let resolvedFamily: String? = {
                switch self {
                case .tranquille:
                    for candidate in Self.publicoNameCandidates {
                        if UIFont(name: candidate, size: size) != nil { return candidate }
                    }
                    return nil
                case .calme:
                    for candidate in Self.canelaNameCandidates {
                        if UIFont(name: candidate, size: size) != nil { return candidate }
                    }
                    return nil
                case .attention:
                    for candidate in Self.proximaNovaNameCandidates {
                        if UIFont(name: candidate, size: size) != nil { return candidate }
                    }
                    return nil
                default:
                    return fontFamily
                }
            }()
            if let family = resolvedFamily, let f = UIFont(name: family, size: size) {
                let traits: [UIFontDescriptor.TraitKey: Any] = [.weight: effective.rawValue]
                let descriptor = f.fontDescriptor.addingAttributes([.traits: traits])
                return UIFont(descriptor: descriptor, size: size)
            }
            return UIFont.systemFont(ofSize: size, weight: effective)
        }

        /// SwiftUI `Font` mirror of `uiFont(size:weight:)` for
        /// non-text-engine views (titles, button labels…).
        public func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            Font(uiFont(size: size, weight: weight.uiKitWeight))
        }
    }

    /// User-facing color scheme override — `.system` follows the
    /// device-wide setting (default), `.light` / `.dark` force a
    /// specific scheme regardless of what iOS does. Mirrors the
    /// pattern most modern apps offer in their own Appearance
    /// section instead of forcing the user out into Settings.app.
    public enum AppearanceMode: String, CaseIterable, Identifiable {
        case system, light, dark

        public var id: String { rawValue }

        /// Maps to SwiftUI's `.preferredColorScheme(_:)` — `nil` for
        /// `.system` so the view inherits whatever iOS decides.
        public var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light:  return .light
            case .dark:   return .dark
            }
        }

        public var label: LocalizedStringKey {
            switch self {
            case .system: return "System"
            case .light:  return "Light"
            case .dark:   return "Dark"
            }
        }

        public var systemImage: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light:  return "sun.max"
            case .dark:   return "moon"
            }
        }
    }

    public enum AccentChoice: String, CaseIterable, Identifiable {
        case pink, purple, blue, teal, green, yellow, orange, red

        public var id: String { rawValue }

        public var color: Color {
            switch self {
            case .pink:   return .pink
            case .purple: return .purple
            case .blue:   return .blue
            case .teal:   return .teal
            case .green:  return .green
            case .yellow: return .yellow
            case .orange: return .orange
            case .red:    return .red
            }
        }

        public var label: LocalizedStringKey {
            switch self {
            case .pink:   return "Pink"
            case .purple: return "Purple"
            case .blue:   return "Blue"
            case .teal:   return "Teal"
            case .green:  return "Green"
            case .yellow: return "Yellow"
            case .orange: return "Orange"
            case .red:    return "Red"
            }
        }
    }

    private let accentKey         = "pinkha.settings.accentColor"
    private let spotlightKey      = "pinkha.settings.spotlightTinted"
    private let recentCountKey    = "pinkha.settings.recentCount"
    private let cursorAccentKey   = "pinkha.settings.cursorFollowsAccent"
    private let appearanceKey     = "pinkha.settings.appearance"
    private let themeKey          = "pinkha.settings.theme"
    private let themeDarkVariantKey = "pinkha.settings.themeDarkVariant"
    private let readerLongPressEnabledKey  = "pinkha.settings.readerLongPressEnabled"
    private let readerFingerCountKey       = "pinkha.settings.readerLongPressFingerCount"
    private let readerHidesStatusBarKey    = "pinkha.settings.readerHidesStatusBar"
    private let hidesAccessoryOffRootKey   = "pinkha.settings.hidesAccessoryOutsideLibraryRoot"
    /// Public so `Haptic` can read the flag without an
    /// `AppSettings` env injection — it's polled from inside the
    /// haptic generators which run in `@MainActor` static functions.
    public static let hapticsKey         = "pinkha.settings.hapticsEnabled"
    /// Public so `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`
    /// can read the flag — UIKit polls that callback at every layout
    /// pass and we can't inject `AppSettings` into a plain
    /// `UIApplicationDelegate`.
    public static let rotationLockKey    = "pinkha.settings.rotationLocked"
    private let linkPreviewsKey          = "pinkha.settings.linkPreviewsEnabled"

    /// When on, the text-input caret + selection highlight use the
    /// chosen accent color. Off by default (white, à la Notion) so
    /// the cursor stays quiet against most block colors.
    public var cursorFollowsAccent: Bool {
        didSet {
            UserDefaults.standard.set(cursorFollowsAccent, forKey: cursorAccentKey)
        }
    }

    /// How many docs the "Recent" strip on the Library home shows.
    /// Bounded 5–20 ; 7 is the default that fits ~2 fully-visible
    /// cards plus a peek of a third on iPhone 17 Pro.
    public var recentCount: Int {
        didSet {
            let clamped = max(5, min(20, recentCount))
            if clamped != recentCount {
                recentCount = clamped
                return
            }
            UserDefaults.standard.set(recentCount, forKey: recentCountKey)
        }
    }

    public var accentChoice: AccentChoice {
        didSet {
            UserDefaults.standard.set(accentChoice.rawValue, forKey: accentKey)
        }
    }

    public var spotlightTinted: Bool {
        didSet {
            UserDefaults.standard.set(spotlightTinted, forKey: spotlightKey)
        }
    }

    /// Whether the global `HapticTapStyle` (and the semantic
    /// `Haptic.tap` / `Haptic.toggle` / … helpers) fire any taptic
    /// feedback. Default on — users who find the per-button buzz
    /// excessive can flip this off in Settings.
    public var hapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticsEnabled, forKey: AppSettings.hapticsKey)
        }
    }

    /// Whether Embed blocks fetch a preview (OpenGraph title, image,
    /// favicon) when a leaf is rendered.
    ///
    /// Default on — the card is the point of the block. Off makes leaf
    /// rendering fully offline: an embed then shows its host and
    /// nothing else. That matters because the fetch is *automatic* —
    /// scrolling past a link is enough to tell its server that this
    /// device opened the note containing it, which is not something
    /// every user wants a private notes app doing on their behalf.
    public var linkPreviewsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(linkPreviewsEnabled, forKey: linkPreviewsKey)
        }
    }

    /// When on, the app refuses to rotate into landscape — handy on
    /// iPhone where a stray wrist twist while reading flips a doc
    /// sideways. Off by default so the existing landscape layout
    /// keeps working. Toggling immediately snaps the active scene
    /// back to portrait and invalidates UIKit's supported-orientation
    /// cache.
    public var rotationLocked: Bool {
        didSet {
            UserDefaults.standard.set(rotationLocked, forKey: AppSettings.rotationLockKey)
            AppSettings.applyRotationLockToScenes(locked: rotationLocked)
        }
    }

    /// Whether the multi-finger long-press gesture toggles reader mode.
    /// Default on — power users who find the gesture intrusive can flip
    /// it off; the eyeglasses entry in the CreateBubble's overflow menu
    /// and the floating exit button stay available either way.
    public var readerLongPressEnabled: Bool {
        didSet {
            UserDefaults.standard.set(readerLongPressEnabled, forKey: readerLongPressEnabledKey)
        }
    }

    /// How many simultaneous touches trigger the reader-mode long-press.
    /// Constrained to 2 or 3 — fewer races with single-finger taps,
    /// more is uncomfortable to perform on iPhone. Default 2.
    public var readerLongPressFingerCount: Int {
        didSet {
            let clamped = max(2, min(3, readerLongPressFingerCount))
            if clamped != readerLongPressFingerCount {
                readerLongPressFingerCount = clamped
                return
            }
            UserDefaults.standard.set(readerLongPressFingerCount, forKey: readerFingerCountKey)
        }
    }

    /// Whether reader mode also hides the iOS status bar. Default off
    /// — most users still want to glance at time/battery while reading.
    /// On = fully-immersive (Lecteur Safari / Kindle style).
    public var readerHidesStatusBar: Bool {
        didSet {
            UserDefaults.standard.set(readerHidesStatusBar, forKey: readerHidesStatusBarKey)
        }
    }

    /// Whether the CreateBubble accessory is hidden when the user is
    /// not at the library root (i.e. inside a shelf, leaf or book).
    /// **Default OFF** — the bubble stays visible everywhere so a
    /// fresh user always has the four primary creation buttons one
    /// tap away. Power users who want a quieter chrome inside a leaf
    /// can flip the toggle ON in Settings → Create bubble.
    public var hidesAccessoryOutsideLibraryRoot: Bool {
        didSet {
            UserDefaults.standard.set(hidesAccessoryOutsideLibraryRoot, forKey: hidesAccessoryOffRootKey)
        }
    }

    /// Pokes UIKit so the orientation change becomes immediate, instead
    /// of waiting for the next device-motion event. `requestGeometryUpdate`
    /// performs the visible rotation ; `setNeedsUpdateOfSupportedInterfaceOrientations`
    /// invalidates the cached "which orientations does this VC accept"
    /// answer so the next query lands on our `AppDelegate` override.
    static func applyRotationLockToScenes(locked: Bool) {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let mask: UIInterfaceOrientationMask = locked ? .portrait : .allButUpsideDown
        let geometry = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        for scene in scenes {
            scene.requestGeometryUpdate(geometry) { _ in }
            scene.windows.first?.rootViewController?
                .setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    /// Books.app-style reading theme applied at the app root. Per-doc
    /// `Leaf.theme` overrides this when set.
    public var theme: Theme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: themeKey)
        }
    }

    /// Global "Dark variant" toggle for the current theme — when on,
    /// every leaf renders its theme's dark palette unless the leaf has
    /// a per-doc override via the sun/moon button in the reader
    /// settings sheet. Mirrors Apple Books' top-level light/dark
    /// switch alongside the Theme picker.
    public var themeDarkVariant: Bool {
        didSet {
            UserDefaults.standard.set(themeDarkVariant, forKey: themeDarkVariantKey)
        }
    }

    /// Light / dark / system override applied at the app root via
    /// `.preferredColorScheme(_:)`. Default `.system` follows iOS.
    public var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: appearanceKey)
            // SwiftUI's `.preferredColorScheme(_:)` on sheets has
            // known quirks (mostly on simulator) — the sheet caches
            // the scheme on its host and `nil` doesn't always
            // release a prior forced override. Setting it on every
            // attached UIWindow via UIKit is the reliable belt-
            // and-suspenders: `.unspecified` truly lets iOS take
            // back control, `.light` / `.dark` force a scheme that
            // covers both the main app *and* any presented sheets.
            applyAppearanceToWindows()
        }
    }

    /// Walks every window of every connected scene and writes the
    /// matching `overrideUserInterfaceStyle`. Called from
    /// `appearance.didSet` and once at the end of `init()` so the
    /// stored preference is honoured at cold launch.
    public func applyAppearanceToWindows() {
        let style: UIUserInterfaceStyle = switch appearance {
        case .system: .unspecified
        case .light:  .light
        case .dark:   .dark
        }
        // Short-circuit when the key window already matches — setting
        // `overrideUserInterfaceStyle` forces a layout pass on every
        // descendant. Skipping the redundant set keeps the
        // backgrounding snapshot fast.
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        if windows.first?.overrideUserInterfaceStyle == style { return }
        // Animate the override flip so the relayout fades in over
        // 0.25s instead of snapping — the actual layout cost is the
        // same, but the perceived "slowness" comes from the abrupt
        // colour swap of the entire view tree (NavStack + tabs +
        // toolbars + cover images), which UIKit handles much better
        // when wrapped in `UIView.animate`.
        UIView.animate(withDuration: 0.25) {
            windows.forEach { $0.overrideUserInterfaceStyle = style }
        }
    }

    public init() {
        let stored = UserDefaults.standard.string(forKey: accentKey)
        // Apple-ecosystem default — sticks closer to the system blue
        // most iOS apps use unless the user picks something else.
        self.accentChoice = AccentChoice(rawValue: stored ?? "") ?? .blue
        // Default off — matches the latest preference. A user that
        // wants the tint flips the toggle in Settings.
        self.spotlightTinted = UserDefaults.standard.bool(forKey: spotlightKey)
        let storedCount = UserDefaults.standard.integer(forKey: recentCountKey)
        self.recentCount = (5...20).contains(storedCount) ? storedCount : 7
        // Default ON — selection lozenge needs the accent tint to be
        // visible. UIKit ties caret colour to selection tint on
        // UITextView, so the caret follows along. A user that
        // prefers white (Notion-style) can flip the toggle off.
        if UserDefaults.standard.object(forKey: cursorAccentKey) != nil {
            self.cursorFollowsAccent = UserDefaults.standard.bool(forKey: cursorAccentKey)
        } else {
            self.cursorFollowsAccent = true
        }
        let storedAppearance = UserDefaults.standard.string(forKey: appearanceKey)
        self.appearance = AppearanceMode(rawValue: storedAppearance ?? "") ?? .system
        let storedTheme = UserDefaults.standard.string(forKey: themeKey)
        self.theme = Theme(rawValue: storedTheme ?? "") ?? .original
        self.themeDarkVariant = UserDefaults.standard.bool(forKey: themeDarkVariantKey)
        // Default ON — users discover the haptic feel and decide
        // whether they want it. Existing users without the key set
        // get the same default behaviour.
        if UserDefaults.standard.object(forKey: AppSettings.hapticsKey) != nil {
            self.hapticsEnabled = UserDefaults.standard.bool(forKey: AppSettings.hapticsKey)
        } else {
            self.hapticsEnabled = true
        }
        // Default ON — same "absent key means default, not false"
        // guard, since `bool(forKey:)` cannot distinguish the two.
        if UserDefaults.standard.object(forKey: linkPreviewsKey) != nil {
            self.linkPreviewsEnabled = UserDefaults.standard.bool(forKey: linkPreviewsKey)
        } else {
            self.linkPreviewsEnabled = true
        }
        // Default OFF — preserves the existing landscape behaviour
        // for users who haven't touched the toggle yet.
        self.rotationLocked = UserDefaults.standard.bool(forKey: AppSettings.rotationLockKey)
        // Reader mode defaults — gesture on, 2 fingers, status bar visible.
        if UserDefaults.standard.object(forKey: readerLongPressEnabledKey) != nil {
            self.readerLongPressEnabled = UserDefaults.standard.bool(forKey: readerLongPressEnabledKey)
        } else {
            self.readerLongPressEnabled = true
        }
        let storedFingers = UserDefaults.standard.integer(forKey: readerFingerCountKey)
        self.readerLongPressFingerCount = (2...3).contains(storedFingers) ? storedFingers : 2
        self.readerHidesStatusBar = UserDefaults.standard.bool(forKey: readerHidesStatusBarKey)
        // Default OFF — the bubble stays visible everywhere by
        // default so fresh users always see the creation actions
        // one tap away. Power users opt in to quieter chrome in
        // Settings.
        self.hidesAccessoryOutsideLibraryRoot = UserDefaults.standard.bool(forKey: hidesAccessoryOffRootKey)
    }

    public var accentColor: Color { accentChoice.color }

    /// Resets every preference back to its factory default —
    /// accent = orange, spotlight tint off, recent count = 7. Used
    /// by the floating "Reset" button in `SettingsView`.
    public func resetToDefaults() {
        accentChoice              = .blue
        spotlightTinted           = false
        recentCount               = 7
        cursorFollowsAccent       = true
        appearance                = .system
        theme                     = .original
        hapticsEnabled            = true
        linkPreviewsEnabled       = true
        rotationLocked            = false
        readerLongPressEnabled    = true
        readerLongPressFingerCount = 2
        readerHidesStatusBar      = false
        hidesAccessoryOutsideLibraryRoot = false
    }
}
