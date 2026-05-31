import Foundation
import SwiftUI

// Swift mirrors of the Rust types serialized by serde

/// Swift mirror of the `Document` Rust type. Decoded from the JSON returned by the FFI.
struct DocumentFfi: Codable {
    let id: String
    let cover: String?
    let title: [InlineTextFfi]
    let blocks: [BlockFfi]
}

/// Swift mirror of a `Block` node. Blocks are recursive (children).
struct BlockFfi: Codable, Identifiable {
    let id: String
    let content: BlockContentFfi
    let children: [BlockFfi]
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
    case divider
    case breadcrumb
    case database(id: String)

    private enum K: String, CodingKey { case Text, Heading, Quote, Todo, Divider, Breadcrumb, Database }
    private struct PayloadHeading: Codable { let level: Int; let text: [InlineTextFfi] }
    private struct PayloadQuote:   Codable { let icon: String; let text: [InlineTextFfi] }
    private struct PayloadTodo:    Codable { let done: Bool; let text: [InlineTextFfi] }
    private struct PayloadDb:      Codable { let id: String }

    init(from decoder: Decoder) throws {
        // Unit variants (Divider, Breadcrumb) are bare strings in serde's externally-tagged format.
        if let sv = try? decoder.singleValueContainer(), let s = try? sv.decode(String.self) {
            if s == "Divider"    { self = .divider;    return }
            if s == "Breadcrumb" { self = .breadcrumb; return }
        }
        let c = try decoder.container(keyedBy: K.self)
        if let v = try? c.decode([InlineTextFfi].self, forKey: .Text)    { self = .text(v); return }
        if let v = try? c.decode(PayloadHeading.self,  forKey: .Heading) { self = .heading(level: v.level, text: v.text); return }
        if let v = try? c.decode(PayloadQuote.self,    forKey: .Quote)   { self = .quote(icon: v.icon, text: v.text); return }
        if let v = try? c.decode(PayloadTodo.self,     forKey: .Todo)    { self = .todo(done: v.done, text: v.text); return }
        if let v = try? c.decode(PayloadDb.self,       forKey: .Database){ self = .database(id: v.id); return }
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
        case .database(let id):
            var c = encoder.container(keyedBy: K.self)
            try c.encode(PayloadDb(id: id), forKey: .Database)
        }
    }

    /// Concatenates the raw text of all inline spans, ignoring styles.
    var plainText: String {
        switch self {
        case .text(let s):         return s.map(\.content).joined()
        case .heading(_, let s):   return s.map(\.content).joined()
        case .quote(_, let s):     return s.map(\.content).joined()
        case .todo(_, let s):      return s.map(\.content).joined()
        default:                   return ""
        }
    }

    /// Returns the inline spans of the block, or an empty array for structural blocks (Divider, etc.).
    var spansOrEmpty: [InlineTextFfi] {
        switch self {
        case .text(let s):       return s
        case .heading(_, let s): return s
        case .quote(_, let s):   return s
        case .todo(_, let s):    return s
        default:                 return []
        }
    }

    /// `true` if this variant is a `.todo` block.
    var isTodo: Bool { if case .todo = self { return true }; return false }
    /// `true` if this is a `.todo` block with `done == true`.
    var isTodoDone: Bool { if case .todo(let d, _) = self { return d }; return false }

    /// Returns a copy of the block with its text replaced by a single unstyled span.
    func withText(_ newText: String, done: Bool = false) -> BlockContentFfi {
        let spans = newText.isEmpty ? [] : [InlineTextFfi(content: newText, styles: [])]
        switch self {
        case .text:              return .text(spans)
        case .heading(let l, _): return .heading(level: l, text: spans)
        case .quote(let i, _):   return .quote(icon: i, text: spans)
        case .todo(_, _):        return .todo(done: done, text: spans)
        default:                 return self
        }
    }

    /// Returns a copy of the block with its spans replaced by `spans`, preserving structure (level, icon, done).
    func withSpans(_ spans: [InlineTextFfi], done: Bool = false) -> BlockContentFfi {
        switch self {
        case .text:              return .text(spans)
        case .heading(let l, _): return .heading(level: l, text: spans)
        case .quote(let i, _):   return .quote(icon: i, text: spans)
        case .todo(_, _):        return .todo(done: done, text: spans)
        default:                 return self
        }
    }
}
