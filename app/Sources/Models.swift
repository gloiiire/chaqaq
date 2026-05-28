import Foundation
import SwiftUI

// Miroirs Swift des types Rust sérialisés par serde

struct DocumentFfi: Codable {
    let id: String
    let cover: String?
    let title: [InlineTextFfi]
    let blocks: [BlockFfi]
}

struct BlockFfi: Codable, Identifiable {
    let id: String
    let content: BlockContentFfi
    let children: [BlockFfi]
}

struct InlineTextFfi: Codable {
    let content: String
    let styles: [InlineStyleFfi]
}

enum InlineStyleFfi: Codable {
    case bold, italic, underline, strikethrough
    case color(String)
    case link(String)

    private enum K: String, CodingKey { case Bold, Italic, Underline, Strikethrough, Color, Link }

    init(from decoder: Decoder) throws {
        if let sv = try? decoder.singleValueContainer(), let s = try? sv.decode(String.self) {
            switch s {
            case "Bold":         self = .bold;         return
            case "Italic":       self = .italic;       return
            case "Underline":    self = .underline;    return
            case "Strikethrough":self = .strikethrough; return
            default: break
            }
        }
        let c = try decoder.container(keyedBy: K.self)
        if let v = try? c.decode(String.self, forKey: .Color) { self = .color(v); return }
        if let v = try? c.decode(String.self, forKey: .Link)  { self = .link(v);  return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "InlineStyle inconnu"))
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

enum BlockContentFfi: Codable {
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
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "BlockContent inconnu"))
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

    var texteSimple: String {
        switch self {
        case .text(let s):         return s.map(\.content).joined()
        case .heading(_, let s):   return s.map(\.content).joined()
        case .quote(_, let s):     return s.map(\.content).joined()
        case .todo(_, let s):      return s.map(\.content).joined()
        default:                   return ""
        }
    }

    var spansOuVide: [InlineTextFfi] {
        switch self {
        case .text(let s):       return s
        case .heading(_, let s): return s
        case .quote(_, let s):   return s
        case .todo(_, let s):    return s
        default:                 return []
        }
    }

    var estTodo: Bool { if case .todo = self { return true }; return false }
    var doneTodo: Bool { if case .todo(let d, _) = self { return d }; return false }

    func avecTexte(_ nouveau: String, done: Bool = false) -> BlockContentFfi {
        let spans = nouveau.isEmpty ? [] : [InlineTextFfi(content: nouveau, styles: [])]
        switch self {
        case .text:              return .text(spans)
        case .heading(let l, _): return .heading(level: l, text: spans)
        case .quote(let i, _):   return .quote(icon: i, text: spans)
        case .todo(_, _):        return .todo(done: done, text: spans)
        default:                 return self
        }
    }

    func avecSpans(_ spans: [InlineTextFfi], done: Bool = false) -> BlockContentFfi {
        switch self {
        case .text:              return .text(spans)
        case .heading(let l, _): return .heading(level: l, text: spans)
        case .quote(let i, _):   return .quote(icon: i, text: spans)
        case .todo(_, _):        return .todo(done: done, text: spans)
        default:                 return self
        }
    }

    func toAttributedString() -> AttributedString {
        let spans: [InlineTextFfi]
        switch self {
        case .text(let s): spans = s
        case .heading(_, let s): spans = s
        case .quote(_, let s): spans = s
        case .todo(_, let s): spans = s
        default: return AttributedString()
        }
        var result = AttributedString()
        for span in spans {
            var part = AttributedString(span.content)
            for style in span.styles {
                switch style {
                case .bold:           part.inlinePresentationIntent = .stronglyEmphasized
                case .italic:         part.inlinePresentationIntent = .emphasized
                case .underline:      part.underlineStyle = .single
                case .strikethrough:  part.strikethroughStyle = .single
                case .color(let nom): part.foregroundColor = couleurDepuisNom(nom)
                case .link(let url):  if let u = URL(string: url) { part.link = u }
                }
            }
            result += part
        }
        return result
    }
}

private func couleurDepuisNom(_ nom: String) -> Color {
    switch nom.lowercased() {
    case "rouge", "red":      return .red
    case "bleu", "blue":      return .blue
    case "vert", "green":     return .green
    case "orange":            return .orange
    case "violet", "purple":  return .purple
    case "gris", "gray":      return .gray
    default:                  return .primary
    }
}
