import Foundation
import SwiftUI

// Swift mirrors of the Rust types serialized by serde

/// Swift mirror of the `Document` Rust type. Decoded from the JSON returned by the FFI.
struct DocumentFfi: Codable {
    let id: String
    let cover: String?
    /// Page icon — emoji (`"📕"`), filename inside `coversDirectory()`, or
    /// remote URL. Decoded as nil for documents created before the field
    /// existed (Rust uses `#[serde(default)]`).
    let icon: String?
    let title: [InlineTextFfi]
    let blocks: [BlockFfi]
    /// Read-only flag. `true` for documents created by imports (Notion/
    /// Bear/Craft default to locked) — the user unlocks before editing.
    /// Decoded as false for legacy documents (Rust uses `#[serde(default)]`).
    let locked: Bool?
    /// Per-document accent color name (e.g. `"red"`) overriding the
    /// app-wide accent from `AppSettings`. `nil` falls back to the
    /// global accent.
    let accentColor: String?
    /// Document-level writing direction (`"ltr"` / `"rtl"`). `nil`
    /// = system locale. Default for every block.
    let textDirection: String?
    /// Per-document Books-style theme name. `nil` inherits the global
    /// `AppSettings.theme`.
    let theme: String?

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
    init(id: String, cover: String?, icon: String?,
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
    init(from decoder: Decoder) throws {
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
struct BlockFfi: Codable, Identifiable {
    let id: String
    let content: BlockContentFfi
    let children: [BlockFfi]
    /// Decoded as nil for documents serialised before this field existed.
    let color: String?
    /// Block-level background color name (highlight). Independent
    /// from `color`. `nil` = no background. Default = nil so pre-
    /// feature constructors and tests keep compiling.
    let backgroundColor: String? = nil
    /// Per-block writing direction (`"ltr"` / `"rtl"`). `nil`
    /// inherits the document-level direction.
    let textDirection: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, content, children, color
        case backgroundColor = "background_color"
        case textDirection = "text_direction"
    }
}

/// A run of text with zero or more inline styles applied to it.
struct InlineTextFfi: Codable, Equatable {
    let content: String
    let styles: [InlineStyleFfi]
}

/// Inline formatting style. Matches the serde externally-tagged representation of `InlineStyle` in Rust.
enum InlineStyleFfi: Codable, Equatable {
    case bold, italic, underline, strikethrough
    case color(String)
    case link(String)

    private enum K: String, CodingKey { case Bold, Italic, Underline, Strikethrough, Color, Link }

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

/// Block content variant. Matches the serde externally-tagged representation of `BlockContent` in Rust.
enum BlockContentFfi: Codable, Equatable {
    case text([InlineTextFfi])
    case heading(level: Int, text: [InlineTextFfi])
    case quote(icon: String, text: [InlineTextFfi])
    case todo(done: Bool, text: [InlineTextFfi])
    case bulletedListItem([InlineTextFfi])
    case numberedListItem([InlineTextFfi])
    case code(language: String, text: String)
    case divider
    case breadcrumb
    case database(id: String)
    /// Reference to a child pinkha page. Mirrors Rust `BlockContent::Page`.
    case page(id: String)
    /// Rich URL bookmark / preview card. Mirrors Rust `BlockContent::Embed`.
    case embed(url: String)

    private enum K: String, CodingKey {
        case Text, Heading, Quote, Todo, BulletedListItem, NumberedListItem, Code, Divider, Breadcrumb, Database, Page, Embed
    }
    private struct PayloadHeading: Codable { let level: Int; let text: [InlineTextFfi] }
    private struct PayloadQuote:   Codable { let icon: String?; let text: [InlineTextFfi] }
    private struct PayloadTodo:    Codable { let done: Bool; let text: [InlineTextFfi] }
    private struct PayloadCode:    Codable { let language: String; let text: String }
    private struct PayloadDb:      Codable { let id: String }
    private struct PayloadPage:    Codable { let id: String }
    private struct PayloadEmbed:   Codable { let url: String }

    init(from decoder: Decoder) throws {
        // Unit variants (Divider, Breadcrumb) are bare strings in serde's externally-tagged format.
        if let sv = try? decoder.singleValueContainer(), let s = try? sv.decode(String.self) {
            if s == "Divider"    { self = .divider;    return }
            if s == "Breadcrumb" { self = .breadcrumb; return }
        }
        let c = try decoder.container(keyedBy: K.self)
        if let v = try? c.decode([InlineTextFfi].self, forKey: .Text)             { self = .text(v); return }
        if let v = try? c.decode(PayloadHeading.self,  forKey: .Heading)          { self = .heading(level: v.level, text: v.text); return }
        if let v = try? c.decode(PayloadQuote.self,    forKey: .Quote)            { self = .quote(icon: v.icon ?? "", text: v.text); return }
        if let v = try? c.decode(PayloadTodo.self,     forKey: .Todo)             { self = .todo(done: v.done, text: v.text); return }
        if let v = try? c.decode([InlineTextFfi].self, forKey: .BulletedListItem) { self = .bulletedListItem(v); return }
        if let v = try? c.decode([InlineTextFfi].self, forKey: .NumberedListItem) { self = .numberedListItem(v); return }
        if let v = try? c.decode(PayloadCode.self,     forKey: .Code)             { self = .code(language: v.language, text: v.text); return }
        if let v = try? c.decode(PayloadDb.self,       forKey: .Database)         { self = .database(id: v.id); return }
        if let v = try? c.decode(PayloadPage.self,     forKey: .Page)             { self = .page(id: v.id); return }
        if let v = try? c.decode(PayloadEmbed.self,    forKey: .Embed)            { self = .embed(url: v.url); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown BlockContent"))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .divider:
            var c = encoder.singleValueContainer(); try c.encode("Divider")
        case .breadcrumb:
            var c = encoder.singleValueContainer(); try c.encode("Breadcrumb")
        case .text(let v):
            var c = encoder.container(keyedBy: K.self); try c.encode(v, forKey: .Text)
        case .heading(let level, let text):
            var c = encoder.container(keyedBy: K.self)
            try c.encode(PayloadHeading(level: level, text: text), forKey: .Heading)
        case .quote(let icon, let text):
            var c = encoder.container(keyedBy: K.self)
            try c.encode(PayloadQuote(icon: icon, text: text), forKey: .Quote)
        case .todo(let done, let text):
            var c = encoder.container(keyedBy: K.self)
            try c.encode(PayloadTodo(done: done, text: text), forKey: .Todo)
        case .bulletedListItem(let v):
            var c = encoder.container(keyedBy: K.self); try c.encode(v, forKey: .BulletedListItem)
        case .numberedListItem(let v):
            var c = encoder.container(keyedBy: K.self); try c.encode(v, forKey: .NumberedListItem)
        case .code(let language, let text):
            var c = encoder.container(keyedBy: K.self)
            try c.encode(PayloadCode(language: language, text: text), forKey: .Code)
        case .database(let id):
            var c = encoder.container(keyedBy: K.self)
            try c.encode(PayloadDb(id: id), forKey: .Database)
        case .page(let id):
            var c = encoder.container(keyedBy: K.self)
            try c.encode(PayloadPage(id: id), forKey: .Page)
        case .embed(let url):
            var c = encoder.container(keyedBy: K.self)
            try c.encode(PayloadEmbed(url: url), forKey: .Embed)
        }
    }

    /// Concatenates the raw text of all inline spans, ignoring styles.
    var plainText: String {
        switch self {
        case .text(let s):              return s.map(\.content).joined()
        case .heading(_, let s):        return s.map(\.content).joined()
        case .quote(_, let s):          return s.map(\.content).joined()
        case .todo(_, let s):           return s.map(\.content).joined()
        case .bulletedListItem(let s):  return s.map(\.content).joined()
        case .numberedListItem(let s):  return s.map(\.content).joined()
        case .code(_, let t):           return t
        default:                        return ""
        }
    }

    /// Returns the inline spans of the block, or an empty array for structural blocks (Divider, etc.).
    var spansOrEmpty: [InlineTextFfi] {
        switch self {
        case .text(let s):              return s
        case .heading(_, let s):        return s
        case .quote(_, let s):          return s
        case .todo(_, let s):           return s
        case .bulletedListItem(let s):  return s
        case .numberedListItem(let s):  return s
        default:                        return []
        }
    }

    /// `true` if this variant is a `.todo` block.
    var isTodo: Bool { if case .todo = self { return true }; return false }
    /// `true` if this is a `.todo` block with `done == true`.
    var isTodoDone: Bool { if case .todo(let d, _) = self { return d }; return false }
    /// `true` if this is a `.page` block (Notion-style child page link).
    /// The editor keeps these tappable even on a locked document since
    /// they're navigation targets, not editable content.
    var isPageReference: Bool { if case .page = self { return true }; return false }

    /// Returns a copy of the block with its text replaced by a single unstyled span.
    func withText(_ newText: String, done: Bool = false) -> BlockContentFfi {
        let spans = newText.isEmpty ? [] : [InlineTextFfi(content: newText, styles: [])]
        switch self {
        case .text:                     return .text(spans)
        case .heading(let l, _):        return .heading(level: l, text: spans)
        case .quote(let i, _):          return .quote(icon: i, text: spans)
        case .todo(_, _):               return .todo(done: done, text: spans)
        case .bulletedListItem:         return .bulletedListItem(spans)
        case .numberedListItem:         return .numberedListItem(spans)
        default:                        return self
        }
    }

    /// Returns a copy of the block with its spans replaced by `spans`, preserving structure (level, icon, done).
    func withSpans(_ spans: [InlineTextFfi], done: Bool = false) -> BlockContentFfi {
        switch self {
        case .text:                     return .text(spans)
        case .heading(let l, _):        return .heading(level: l, text: spans)
        case .quote(let i, _):          return .quote(icon: i, text: spans)
        case .todo(_, _):               return .todo(done: done, text: spans)
        case .bulletedListItem:         return .bulletedListItem(spans)
        case .numberedListItem:         return .numberedListItem(spans)
        default:                        return self
        }
    }
}

// ── Database models ───────────────────────────────────────────────────────────

/// Aggregation function for Rollup columns.
enum AggregateFfi: String, Codable, Equatable {
    case count = "Count", sum = "Sum", average = "Average", min = "Min", max = "Max"
}

/// Matches serde's externally-tagged representation of `PropertyType`.
enum PropertyTypeFfi: Codable, Equatable {
    case title, text, number, date, checkbox, url
    case selection([String])
    case selectionMultiple([String])
    case relation(dbId: String)
    case rollup(relationPropId: String, targetPropId: String, aggregate: AggregateFfi)

    private enum K: String, CodingKey {
        case Title, Text, Number, Date, Checkbox, Url
        case Selection, SelectionMultiple, Relation, Rollup
    }
    private struct RelationPayload: Codable { let db_id: String }
    private struct RollupPayload: Codable {
        let relation_prop_id: String; let target_prop_id: String; let aggregate: AggregateFfi
    }

    init(from decoder: Decoder) throws {
        if let sv = try? decoder.singleValueContainer(), let s = try? sv.decode(String.self) {
            switch s {
            case "Title":    self = .title;    return
            case "Text":     self = .text;     return
            case "Number":   self = .number;   return
            case "Date":     self = .date;     return
            case "Checkbox": self = .checkbox; return
            case "Url":      self = .url;      return
            default: break
            }
        }
        let c = try decoder.container(keyedBy: K.self)
        if let v = try? c.decode([String].self,        forKey: .Selection)         { self = .selection(v); return }
        if let v = try? c.decode([String].self,        forKey: .SelectionMultiple) { self = .selectionMultiple(v); return }
        if let v = try? c.decode(RelationPayload.self, forKey: .Relation)          { self = .relation(dbId: v.db_id); return }
        if let v = try? c.decode(RollupPayload.self,   forKey: .Rollup)            {
            self = .rollup(relationPropId: v.relation_prop_id, targetPropId: v.target_prop_id, aggregate: v.aggregate); return
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown PropertyType"))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .title:    var c = encoder.singleValueContainer(); try c.encode("Title")
        case .text:     var c = encoder.singleValueContainer(); try c.encode("Text")
        case .number:   var c = encoder.singleValueContainer(); try c.encode("Number")
        case .date:     var c = encoder.singleValueContainer(); try c.encode("Date")
        case .checkbox: var c = encoder.singleValueContainer(); try c.encode("Checkbox")
        case .url:      var c = encoder.singleValueContainer(); try c.encode("Url")
        case .selection(let opts):
            var c = encoder.container(keyedBy: K.self); try c.encode(opts, forKey: .Selection)
        case .selectionMultiple(let opts):
            var c = encoder.container(keyedBy: K.self); try c.encode(opts, forKey: .SelectionMultiple)
        case .relation(let dbId):
            var c = encoder.container(keyedBy: K.self)
            try c.encode(RelationPayload(db_id: dbId), forKey: .Relation)
        case .rollup(let relId, let tgtId, let agg):
            var c = encoder.container(keyedBy: K.self)
            try c.encode(RollupPayload(relation_prop_id: relId, target_prop_id: tgtId, aggregate: agg), forKey: .Rollup)
        }
    }

    var icon: String {
        switch self {
        case .title:             return "textformat"
        case .text:              return "text.alignleft"
        case .number:            return "number"
        case .checkbox:          return "checkmark.square"
        case .date:              return "calendar"
        case .url:               return "link"
        case .selection:         return "list.bullet"
        case .selectionMultiple: return "list.bullet.indent"
        case .relation:          return "arrow.triangle.2.circlepath"
        case .rollup:            return "function"
        }
    }
}

/// A column definition in a database. Mirrors Rust `Property`.
struct PropertyFfi: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let propertyType: PropertyTypeFfi

    enum CodingKeys: String, CodingKey { case id, name, propertyType = "type_" }
}

/// Matches serde's externally-tagged representation of `PropertyValue`.
enum PropertyValueFfi: Codable, Equatable {
    case title([InlineTextFfi])
    case text(String)
    case number(Double)
    case selection(String?)
    case selectionMultiple([String])
    case date(String)
    case checkbox(Bool)
    case url(String)
    case relation([String])
    case empty

    private enum K: String, CodingKey {
        case Title, Text, Number, Selection, SelectionMultiple, Date, Checkbox, Url, Relation
    }

    init(from decoder: Decoder) throws {
        if let sv = try? decoder.singleValueContainer(), let s = try? sv.decode(String.self) {
            if s == "Empty" { self = .empty; return }
        }
        let c = try decoder.container(keyedBy: K.self)
        if let v = try? c.decode([InlineTextFfi].self, forKey: .Title)             { self = .title(v); return }
        if let v = try? c.decode(String.self,          forKey: .Text)              { self = .text(v); return }
        if let v = try? c.decode(Double.self,          forKey: .Number)            { self = .number(v); return }
        if c.contains(.Selection)                                                  { self = .selection(try? c.decode(String.self, forKey: .Selection)); return }
        if let v = try? c.decode([String].self,        forKey: .SelectionMultiple) { self = .selectionMultiple(v); return }
        if let v = try? c.decode(String.self,          forKey: .Date)              { self = .date(v); return }
        if let v = try? c.decode(Bool.self,            forKey: .Checkbox)          { self = .checkbox(v); return }
        if let v = try? c.decode(String.self,          forKey: .Url)              { self = .url(v); return }
        if let v = try? c.decode([String].self,        forKey: .Relation)          { self = .relation(v); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown PropertyValue"))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .empty:
            var c = encoder.singleValueContainer(); try c.encode("Empty")
        case .title(let v):
            var c = encoder.container(keyedBy: K.self); try c.encode(v, forKey: .Title)
        case .text(let v):
            var c = encoder.container(keyedBy: K.self); try c.encode(v, forKey: .Text)
        case .number(let v):
            var c = encoder.container(keyedBy: K.self); try c.encode(v, forKey: .Number)
        case .selection(let v):
            var c = encoder.container(keyedBy: K.self); try c.encode(v, forKey: .Selection)
        case .selectionMultiple(let v):
            var c = encoder.container(keyedBy: K.self); try c.encode(v, forKey: .SelectionMultiple)
        case .date(let v):
            var c = encoder.container(keyedBy: K.self); try c.encode(v, forKey: .Date)
        case .checkbox(let v):
            var c = encoder.container(keyedBy: K.self); try c.encode(v, forKey: .Checkbox)
        case .url(let v):
            var c = encoder.container(keyedBy: K.self); try c.encode(v, forKey: .Url)
        case .relation(let v):
            var c = encoder.container(keyedBy: K.self); try c.encode(v, forKey: .Relation)
        }
    }

    /// Plain-text representation of the value (for read-only cells).
    var displayText: String {
        switch self {
        case .title(let s):             return s.map(\.content).joined()
        case .text(let s):              return s
        case .number(let n):            return n.formatted()
        case .selection(let s):         return s ?? ""
        case .selectionMultiple(let s): return s.joined(separator: ", ")
        case .date(let s):              return s
        case .checkbox:                 return ""
        case .url(let s):               return s
        case .relation:                 return "→"
        case .empty:                    return ""
        }
    }
}

/// A database row. Mirrors Rust `Entry`.
///
/// `documentId` is set for rows imported from Notion / Craft (where every page
/// becomes both a Document and a row). When set, renaming the row via the FFI
/// `updateEntry` call propagates the new title to the underlying note. `nil`
/// for standalone tabular rows with no attached page.
struct EntryFfi: Codable, Identifiable {
    let id: String
    let createdAt: String
    /// User-editable publish timestamp. Defaults to `createdAt` at
    /// insert on the Rust side, so untouched entries behave
    /// identically. Empty string on legacy entries (pre-field) is
    /// treated as "fall back to createdAt" by the query path.
    var publishedAt: String

    /// Whether the entry's publish date has been manually overridden
    /// (i.e. differs from `createdAt`). Used by the UI to show a
    /// little "scheduled" indicator next to the date.
    var hasCustomPublishDate: Bool {
        !publishedAt.isEmpty && publishedAt != createdAt
    }

    /// Effective publish date — manual override when set, else
    /// `createdAt`. Mirrors the Rust query's fallback logic so the
    /// row's displayed date matches the column the user sorted by.
    var effectivePublishedAt: String {
        publishedAt.isEmpty ? createdAt : publishedAt
    }
    var values: [String: PropertyValueFfi]
    let documentId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case publishedAt = "published_at"
        case values
        case documentId = "document_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        createdAt   = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        publishedAt = (try? c.decode(String.self, forKey: .publishedAt)) ?? ""
        values      = try c.decode([String: PropertyValueFfi].self, forKey: .values)
        documentId  = try c.decodeIfPresent(String.self, forKey: .documentId)
    }

    init(
        id: String,
        createdAt: String,
        publishedAt: String = "",
        values: [String: PropertyValueFfi],
        documentId: String?
    ) {
        self.id          = id
        self.createdAt   = createdAt
        self.publishedAt = publishedAt
        self.values      = values
        self.documentId  = documentId
    }
}

/// Full database payload returned by `getDatabaseJson`. Mirrors Rust `Database`.
struct DatabaseFfi: Codable {
    let id: String
    let title: [InlineTextFfi]
    /// Optional banner image identifier — URL or local filename. Mirrors
    /// the document cover surface so the doc-like DB header can render
    /// one. Decoded explicitly because Codable synthesis won't accept a
    /// missing key without an explicit `init(from:)`.
    var cover: String?
    /// Optional emoji / filename / URL displayed next to the title.
    var icon: String?
    /// Rich-text description shown under the title in the header. Empty
    /// means "no description".
    var description: [InlineTextFfi]
    let properties: [PropertyFfi]
    var entries: [EntryFfi]
    /// At least one view is always present (Rust `Database::new` seeds a
    /// default "List" view). `#[serde(default)]` would keep us safe against
    /// older payloads — Codable's Optional support gives the same guarantee.
    let views: [ViewFfi]?

    /// Read-only flag. Mirrors `Document.locked` ; defaults `false`
    /// when missing so old payloads stay decodable.
    var locked: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, cover, icon, description, locked, properties, entries, views
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        title       = try c.decode([InlineTextFfi].self, forKey: .title)
        cover       = try c.decodeIfPresent(String.self, forKey: .cover)
        icon        = try c.decodeIfPresent(String.self, forKey: .icon)
        description = (try? c.decode([InlineTextFfi].self, forKey: .description)) ?? []
        locked      = (try? c.decode(Bool.self, forKey: .locked)) ?? false
        properties  = try c.decode([PropertyFfi].self, forKey: .properties)
        entries     = try c.decode([EntryFfi].self, forKey: .entries)
        views       = try c.decodeIfPresent([ViewFfi].self, forKey: .views)
    }

    init(
        id: String,
        title: [InlineTextFfi],
        cover: String? = nil,
        icon: String? = nil,
        description: [InlineTextFfi] = [],
        locked: Bool = false,
        properties: [PropertyFfi],
        entries: [EntryFfi],
        views: [ViewFfi]? = nil
    ) {
        self.id          = id
        self.title       = title
        self.cover       = cover
        self.icon        = icon
        self.description = description
        self.locked      = locked
        self.properties  = properties
        self.entries     = entries
        self.views       = views
    }
}

/// View layout discriminator. Mirrors the Rust `ViewType` externally-tagged
/// serde encoding. `List` and `Table` and `Gallery` are unit variants ;
/// `Kanban` and `Calendar` carry an associated property UUID.
enum ViewTypeFfi: Equatable {
    case list
    case table
    case kanban(groupBy: String)
    case calendar(propertyId: String)
    case gallery

    var systemImage: String {
        switch self {
        case .list:     return "list.bullet"
        case .table:    return "tablecells"
        case .kanban:   return "rectangle.split.3x1"
        case .calendar: return "calendar"
        case .gallery:  return "square.grid.2x2"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .list:     return "List"
        case .table:    return "Table"
        case .kanban:   return "Board"
        case .calendar: return "Calendar"
        case .gallery:  return "Gallery"
        }
    }
}

extension ViewTypeFfi: Codable {
    init(from decoder: Decoder) throws {
        // serde unit variants encode as bare strings ("List", "Table",
        // "Gallery") ; struct variants encode as { "Kanban": { … } } /
        // { "Calendar": { … } } single-key objects.
        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            switch raw {
            case "List":    self = .list;    return
            case "Table":   self = .table;   return
            case "Gallery": self = .gallery; return
            default: break
            }
        }
        let c = try decoder.container(keyedBy: GenericKey.self)
        guard let key = c.allKeys.first else {
            throw DecodingError.dataCorruptedError(
                forKey: GenericKey(""),
                in: c,
                debugDescription: "empty ViewType")
        }
        let payload = try c.nestedContainer(keyedBy: GenericKey.self, forKey: key)
        switch key.stringValue {
        case "Kanban":
            let groupBy = try payload.decode(String.self, forKey: GenericKey("group_by"))
            self = .kanban(groupBy: groupBy)
        case "Calendar":
            let prop = try payload.decode(String.self, forKey: GenericKey("property_id"))
            self = .calendar(propertyId: prop)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c,
                debugDescription: "unknown ViewType variant: \(key.stringValue)")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .list:    var s = encoder.singleValueContainer(); try s.encode("List")
        case .table:   var s = encoder.singleValueContainer(); try s.encode("Table")
        case .gallery: var s = encoder.singleValueContainer(); try s.encode("Gallery")
        case .kanban(let g):
            var c = encoder.container(keyedBy: GenericKey.self)
            var n = c.nestedContainer(keyedBy: GenericKey.self, forKey: GenericKey("Kanban"))
            try n.encode(g, forKey: GenericKey("group_by"))
        case .calendar(let p):
            var c = encoder.container(keyedBy: GenericKey.self)
            var n = c.nestedContainer(keyedBy: GenericKey.self, forKey: GenericKey("Calendar"))
            try n.encode(p, forKey: GenericKey("property_id"))
        }
    }
}

/// Tiny untyped CodingKey for tagged-enum decoding. Used by `ViewTypeFfi`
/// and any future externally-tagged enum that doesn't deserve its own
/// dedicated key type.
private struct GenericKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Swift mirror of Rust `View`. Only the fields the UI consumes today.
struct ViewFfi: Codable, Identifiable {
    let id: String
    let name: String
    /// `type_` on Rust side ; `type` on Swift side (reserved word — gets
    /// renamed via CodingKeys). Drives which view component renders.
    var type: ViewTypeFfi = .list
    let sorts: [SortFfi]

    enum CodingKeys: String, CodingKey {
        case id, name
        case type = "type_"
        case sorts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id    = try c.decode(String.self, forKey: .id)
        name  = try c.decode(String.self, forKey: .name)
        type  = (try? c.decode(ViewTypeFfi.self, forKey: .type)) ?? .list
        sorts = (try? c.decode([SortFfi].self, forKey: .sorts)) ?? []
    }

    init(id: String, name: String, type: ViewTypeFfi = .list, sorts: [SortFfi] = []) {
        self.id = id
        self.name = name
        self.type = type
        self.sorts = sorts
    }
}

/// Swift mirror of Rust `Sort`. `order` is `"Ascending"` / `"Descending"`,
/// `source` is `"Property"` / `"Created"` / `"ManualThenCreated"` — match the
/// serde externally-tagged enum encoding.
struct SortFfi: Codable, Equatable {
    let propertyId: String
    let order: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case propertyId = "property_id"
        case order
        case source
    }
}
