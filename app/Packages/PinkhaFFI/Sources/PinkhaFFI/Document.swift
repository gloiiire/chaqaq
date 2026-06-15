import Foundation
import SwiftUI

// Document, Block, InlineText, InlineStyle.

/// Swift mirror of the `Document` Rust type. Decoded from the JSON returned by the FFI.
public struct DocumentFfi: Codable {
    public let id: String
    public let cover: String?
    /// Page icon — emoji (`"📕"`), filename inside `coversDirectory()`, or
    /// remote URL. Decoded as nil for documents created before the field
    /// existed (Rust uses `#[serde(default)]`).
    public let icon: String?
    public let title: [InlineTextFfi]
    public let blocks: [BlockFfi]
    /// Read-only flag. `true` for documents created by imports (Notion/
    /// Bear/Craft default to locked) — the user unlocks before editing.
    /// Decoded as false for legacy documents (Rust uses `#[serde(default)]`).
    public let locked: Bool?
    /// Per-document accent color name (e.g. `"red"`) overriding the
    /// app-wide accent from `AppSettings`. `nil` falls back to the
    /// global accent.
    public let accentColor: String?
    /// Document-level writing direction (`"ltr"` / `"rtl"`). `nil`
    /// = system locale. Default for every block.
    public let textDirection: String?
    /// Per-document Books-style theme name. `nil` inherits the global
    /// `AppSettings.theme`.
    public let theme: String?

    enum CodingKeys: String, CodingKey {
        case id, cover, icon, title, blocks, locked, theme
        case accentColor = "accent_color"
        case textDirection = "text_direction"
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
         theme: String? = nil) {
        self.id = id
        self.cover = cover
        self.icon = icon
        self.title = title
        self.blocks = blocks
        self.locked = locked
        self.accentColor = accentColor
        self.textDirection = textDirection
        self.theme = theme
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
        id            = try c.decode(String.self, forKey: .id)
        cover         = try c.decodeIfPresent(String.self, forKey: .cover)
        icon          = try c.decodeIfPresent(String.self, forKey: .icon)
        title         = try c.decode([InlineTextFfi].self, forKey: .title)
        blocks        = try c.decode([BlockFfi].self, forKey: .blocks)
        locked        = try c.decodeIfPresent(Bool.self, forKey: .locked)
        accentColor   = try c.decodeIfPresent(String.self, forKey: .accentColor)
        textDirection = try c.decodeIfPresent(String.self, forKey: .textDirection)
        theme         = try c.decodeIfPresent(String.self, forKey: .theme)
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
    /// Decoded as nil for documents serialised before this field existed.
    public let color: String?
    /// Block-level background color name (highlight). Independent
    /// from `color`. `nil` = no background. Default = nil so pre-
    /// feature constructors and tests keep compiling.
    public let backgroundColor: String?
    /// Per-block writing direction (`"ltr"` / `"rtl"`). `nil`
    /// inherits the document-level direction.
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
