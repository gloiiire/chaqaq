import Foundation
import SwiftUI

// Leaf, Block, InlineText, InlineStyle.

/// Swift mirror of the `Leaf` Rust type. Decoded from the JSON returned by the FFI.
public struct LeafFfi: Codable {
    public let id: String
    public let cover: String?
    /// Page icon — emoji (`"📕"`), filename inside `coversDirectory()`, or
    /// remote URL. Decoded as nil for leaves created before the field
    /// existed (Rust uses `#[serde(default)]`).
    public let icon: String?
    public let title: [InlineTextFfi]
    public let blocks: [BlockFfi]
    /// Read-only flag. `true` for leaves created by imports (Notion/
    /// Bear/Craft default to locked) — the user unlocks before editing.
    /// Decoded as false for legacy leaves (Rust uses `#[serde(default)]`).
    public let locked: Bool?
    /// Per-leaf accent color name (e.g. `"red"`) overriding the
    /// app-wide accent from `AppSettings`. `nil` falls back to the
    /// global accent.
    public let accentColor: String?
    /// Leaf-level writing direction (`"ltr"` / `"rtl"`). `nil`
    /// = system locale. Default for every block.
    public let textDirection: String?
    /// Per-leaf Books-style theme name. `nil` inherits the global
    /// `AppSettings.theme`.
    public let theme: String?
    /// PRO-62 : per-leaf reader-settings bundle (font scale +
    /// family + bold + 4 spacing values + justify + dark variant +
    /// custom-layout flag). `nil` falls back to the theme defaults.
    public let readerSettings: LeafReaderSettings?

    enum CodingKeys: String, CodingKey {
        case id, cover, icon, title, blocks, locked, theme
        case accentColor = "accent_color"
        case textDirection = "text_direction"
        case readerSettings = "reader_settings"
    }

    /// Memberwise init kept around so existing test fixtures that
    /// pre-date the per-doc accent / text-direction / theme fields
    /// (`CodableRoundTripTests`) still compile without listing every
    /// new optional. Property-level defaults can't live here because
    /// they break the `Codable` synth (see the explicit `init(from:)`
    /// below).
    public init(id: String, cover: String?, icon: String?,
         title: [InlineTextFfi], blocks: [BlockFfi], locked: Bool?,
         accentColor: String? = nil, textDirection: String? = nil,
         theme: String? = nil, readerSettings: LeafReaderSettings? = nil) {
        self.id = id
        self.cover = cover
        self.icon = icon
        self.title = title
        self.blocks = blocks
        self.locked = locked
        self.accentColor = accentColor
        self.textDirection = textDirection
        self.theme = theme
        self.readerSettings = readerSettings
    }

    /// Explicit `init(from:)` — Swift's auto-synthesized decoder
    /// skips properties that have a `let X = value` default, which
    /// silently dropped the per-doc theme / accent color / text
    /// direction on reload (user reported "theme isn't saved when I
    /// quit the doc"). Calling `decodeIfPresent` ourselves makes
    /// every optional behave the same way regardless of whether the
    /// property declaration carries a default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(String.self, forKey: .id)
        cover          = try c.decodeIfPresent(String.self, forKey: .cover)
        icon           = try c.decodeIfPresent(String.self, forKey: .icon)
        title          = try c.decode([InlineTextFfi].self, forKey: .title)
        blocks         = try c.decode([BlockFfi].self, forKey: .blocks)
        locked         = try c.decodeIfPresent(Bool.self, forKey: .locked)
        accentColor    = try c.decodeIfPresent(String.self, forKey: .accentColor)
        textDirection  = try c.decodeIfPresent(String.self, forKey: .textDirection)
        theme          = try c.decodeIfPresent(String.self, forKey: .theme)
        readerSettings = try c.decodeIfPresent(LeafReaderSettings.self, forKey: .readerSettings)
    }
}

/// Swift mirror of the Rust `ReaderSettings` struct (PRO-62).
/// Stored as a JSON blob on the leaf row ; updated via
/// `PinkhaApi.updateLeafReaderSettings`. Defaults mirror Apple Books'
/// `BookTheme` Core Data factory values (line_spacing 1.4, etc.).
public struct LeafReaderSettings: Codable, Equatable {
    public var fontScale: Double
    public var fontFamily: String?
    public var bold: Bool
    public var lineSpacing: Double
    public var letterSpacing: Double
    public var wordSpacing: Double
    public var marginScale: Double
    public var justify: Bool
    /// Legacy bool — pre-PRO-62-step-N leaves only carried this.
    /// New code reads `themeAppearance` instead and falls back to
    /// this value when the appearance is `"settings"` and the user
    /// has never edited the global Settings toggle. Kept on the wire
    /// for backward decode + so older app versions still see something
    /// sensible if they hit a freshly-written row.
    public var themeDarkVariant: Bool
    public var customLayoutEnabled: Bool
    /// 5-way appearance choice mirroring Apple Books :
    /// `"light" | "dark" | "system" | "ambient" | "settings"`.
    /// Resolved at render time by `ReaderAppearance.effectiveDark`.
    /// Defaults to `"settings"` so a fresh leaf inherits the user's
    /// app-wide preference.
    public var themeAppearance: String

    enum CodingKeys: String, CodingKey {
        case fontScale = "font_scale"
        case fontFamily = "font_family"
        case bold
        case lineSpacing = "line_spacing"
        case letterSpacing = "letter_spacing"
        case wordSpacing = "word_spacing"
        case marginScale = "margin_scale"
        case justify
        case themeDarkVariant = "theme_dark_variant"
        case customLayoutEnabled = "custom_layout_enabled"
        case themeAppearance = "theme_appearance"
    }

    public init(
        fontScale: Double = 1.0,
        fontFamily: String? = nil,
        bold: Bool = false,
        lineSpacing: Double = 1.4,
        letterSpacing: Double = 0.0,
        wordSpacing: Double = 0.0,
        marginScale: Double = 0.0,
        justify: Bool = false,
        themeDarkVariant: Bool = false,
        customLayoutEnabled: Bool = false,
        themeAppearance: String = "settings"
    ) {
        self.fontScale = fontScale
        self.fontFamily = fontFamily
        self.bold = bold
        self.lineSpacing = lineSpacing
        self.letterSpacing = letterSpacing
        self.wordSpacing = wordSpacing
        self.marginScale = marginScale
        self.justify = justify
        self.themeDarkVariant = themeDarkVariant
        self.customLayoutEnabled = customLayoutEnabled
        self.themeAppearance = themeAppearance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontScale           = try c.decodeIfPresent(Double.self, forKey: .fontScale) ?? 1.0
        fontFamily          = try c.decodeIfPresent(String.self, forKey: .fontFamily)
        bold                = try c.decodeIfPresent(Bool.self,   forKey: .bold) ?? false
        lineSpacing         = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 1.4
        letterSpacing       = try c.decodeIfPresent(Double.self, forKey: .letterSpacing) ?? 0.0
        wordSpacing         = try c.decodeIfPresent(Double.self, forKey: .wordSpacing) ?? 0.0
        marginScale         = try c.decodeIfPresent(Double.self, forKey: .marginScale) ?? 0.0
        justify             = try c.decodeIfPresent(Bool.self,   forKey: .justify) ?? false
        themeDarkVariant    = try c.decodeIfPresent(Bool.self,   forKey: .themeDarkVariant) ?? false
        customLayoutEnabled = try c.decodeIfPresent(Bool.self,   forKey: .customLayoutEnabled) ?? false
        themeAppearance     = try c.decodeIfPresent(String.self, forKey: .themeAppearance) ?? "settings"
    }

    /// Explicit encoder. Swift would auto-synthesize this in theory,
    /// but the bug "I picked Dark on the leaf, exited, came back —
    /// it's Light again" pointed at a silent drop of the new
    /// `theme_appearance` field on save. Writing every field out
    /// here makes the wire format unambiguous and easy to verify in
    /// the FFI integration tests.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontScale,           forKey: .fontScale)
        try c.encodeIfPresent(fontFamily, forKey: .fontFamily)
        try c.encode(bold,                forKey: .bold)
        try c.encode(lineSpacing,         forKey: .lineSpacing)
        try c.encode(letterSpacing,       forKey: .letterSpacing)
        try c.encode(wordSpacing,         forKey: .wordSpacing)
        try c.encode(marginScale,         forKey: .marginScale)
        try c.encode(justify,             forKey: .justify)
        try c.encode(themeDarkVariant,    forKey: .themeDarkVariant)
        try c.encode(customLayoutEnabled, forKey: .customLayoutEnabled)
        try c.encode(themeAppearance,     forKey: .themeAppearance)
    }
}

/// 5-way appearance choice for the per-leaf reader theme. Mirrors
/// Apple Books' light/dark popover — wraps the `theme_appearance`
/// string field on `LeafReaderSettings` with a type-safe enum + a
/// resolver that maps the choice + ambient state down to the final
/// dark/light Bool used by the renderer.
public enum ReaderAppearance: String, CaseIterable, Sendable {
    case light    = "light"
    case dark     = "dark"
    case system   = "system"
    case ambient  = "ambient"
    case settings = "settings"

    /// Lossy parse — anything we don't recognise (older app version
    /// writing a new variant we don't know yet, corrupted JSON, …)
    /// falls back to `.settings` so the user's app-wide preference
    /// still wins instead of silently forcing light mode.
    public static func parse(_ raw: String?) -> ReaderAppearance {
        guard let raw = raw, let v = ReaderAppearance(rawValue: raw) else {
            return .settings
        }
        return v
    }

    /// Resolves the appearance choice down to the final dark Bool the
    /// renderer needs. `systemIsDark` should come from
    /// `UITraitCollection.current.userInterfaceStyle` (NOT SwiftUI's
    /// `colorScheme` env, which is already overridden when the user
    /// flipped a per-leaf variant). `settingsIsDark` is the app-wide
    /// `AppSettings.themeDarkVariant` Bool.
    ///
    /// `ambient` has no public iOS API — we fall back to system so the
    /// choice is at least sensible, and the menu label still tells the
    /// user what they picked.
    public func effectiveDark(systemIsDark: Bool, settingsIsDark: Bool) -> Bool {
        switch self {
        case .light:    return false
        case .dark:     return true
        case .system:   return systemIsDark
        case .ambient:  return systemIsDark
        case .settings: return settingsIsDark
        }
    }
}

/// Swift mirror of a `Block` node. Blocks are recursive (children).
///
/// `color` is the block-level text color name (e.g. `"red"`). When present
/// it applies to every span that doesn't carry its own inline color —
/// inline color always wins over block color at render time. `nil` means
/// the block inherits the default theme color.
public struct BlockFfi: Codable, Identifiable {
    public let id: String
    public let content: BlockContentFfi
    public let children: [BlockFfi]
    /// Decoded as nil for leaves serialised before this field existed.
    public let color: String?
    /// Block-level background color name (highlight). Independent
    /// from `color`. `nil` = no background. Default = nil so pre-
    /// feature constructors and tests keep compiling.
    public let backgroundColor: String?
    /// Per-block writing direction (`"ltr"` / `"rtl"`). `nil`
    /// inherits the leaf-level direction.
    public let textDirection: String?

    enum CodingKeys: String, CodingKey {
        case id, content, children, color
        case backgroundColor = "background_color"
        case textDirection = "text_direction"
    }

    public init(
        id: String,
        content: BlockContentFfi,
        children: [BlockFfi] = [],
        color: String? = nil,
        backgroundColor: String? = nil,
        textDirection: String? = nil
    ) {
        self.id = id
        self.content = content
        self.children = children
        self.color = color
        self.backgroundColor = backgroundColor
        self.textDirection = textDirection
    }
}

/// A run of text with zero or more inline styles applied to it.
public struct InlineTextFfi: Codable, Equatable {
    public let content: String
    public let styles: [InlineStyleFfi]

    public init(content: String, styles: [InlineStyleFfi]) {
        self.content = content
        self.styles = styles
    }
}
public enum InlineStyleFfi: Codable, Equatable {
    case bold, italic, underline, strikethrough
    case color(String)
    case link(String)

    private enum K: String, CodingKey { case Bold, Italic, Underline, Strikethrough, Color, Link }

    public init(from decoder: Decoder) throws {
        // Unit variants are serialized as plain strings by serde.
        if let sv = try? decoder.singleValueContainer(), let s = try? sv.decode(String.self) {
            switch s {
            case "Bold":         self = .bold;         return
            case "Italic":       self = .italic;       return
            case "Underline":    self = .underline;    return
            case "Strikethrough":self = .strikethrough; return
            default: break
            }
        }
        // Associated variants are serialized as keyed objects.
        let c = try decoder.container(keyedBy: K.self)
        if let v = try? c.decode(String.self, forKey: .Color) { self = .color(v); return }
        if let v = try? c.decode(String.self, forKey: .Link)  { self = .link(v);  return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown InlineStyle"))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .bold:         var c = encoder.singleValueContainer(); try c.encode("Bold")
        case .italic:       var c = encoder.singleValueContainer(); try c.encode("Italic")
        case .underline:    var c = encoder.singleValueContainer(); try c.encode("Underline")
        case .strikethrough:var c = encoder.singleValueContainer(); try c.encode("Strikethrough")
        case .color(let v): var c = encoder.container(keyedBy: K.self); try c.encode(v, forKey: .Color)
        case .link(let v):  var c = encoder.container(keyedBy: K.self); try c.encode(v, forKey: .Link)
        }
    }
}
