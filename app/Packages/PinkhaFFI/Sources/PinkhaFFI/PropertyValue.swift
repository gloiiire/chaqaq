import Foundation
import SwiftUI

// PropertyValue — the tagged enum cells store at runtime.

public enum PropertyValueFfi: Codable, Equatable {
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
    public var displayText: String {
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
