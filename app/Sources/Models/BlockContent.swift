import Foundation
import SwiftUI

// BlockContent — the big tagged enum.

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
