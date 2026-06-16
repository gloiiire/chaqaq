import Foundation
import SwiftUI

// Book property metadata: Aggregate, PropertyType, Property.

// ── Book models ───────────────────────────────────────────────────────────

/// Aggregation function for Rollup columns.
public enum AggregateFfi: String, Codable, Equatable {
    case count = "Count", sum = "Sum", average = "Average", min = "Min", max = "Max"
}

/// Matches serde's externally-tagged representation of `PropertyType`.
public enum PropertyTypeFfi: Codable, Equatable {
    case title, text, number, date, checkbox, url
    case selection([String])
    case selectionMultiple([String])
    case relation(bookId: String)
    case rollup(relationPropId: String, targetPropId: String, aggregate: AggregateFfi)

    private enum K: String, CodingKey {
        case Title, Text, Number, Date, Checkbox, Url
        case Selection, SelectionMultiple, Relation, Rollup
    }
    private struct RelationPayload: Codable { let book_id: String }
    private struct RollupPayload: Codable {
        let relation_prop_id: String; let target_prop_id: String; let aggregate: AggregateFfi
    }

    public init(from decoder: Decoder) throws {
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
        if let v = try? c.decode(RelationPayload.self, forKey: .Relation)          { self = .relation(bookId: v.book_id); return }
        if let v = try? c.decode(RollupPayload.self,   forKey: .Rollup)            {
            self = .rollup(relationPropId: v.relation_prop_id, targetPropId: v.target_prop_id, aggregate: v.aggregate); return
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown PropertyType"))
    }

    public func encode(to encoder: Encoder) throws {
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
        case .relation(let bookId):
            var c = encoder.container(keyedBy: K.self)
            try c.encode(RelationPayload(book_id: bookId), forKey: .Relation)
        case .rollup(let relId, let tgtId, let agg):
            var c = encoder.container(keyedBy: K.self)
            try c.encode(RollupPayload(relation_prop_id: relId, target_prop_id: tgtId, aggregate: agg), forKey: .Rollup)
        }
    }

    public var icon: String {
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

/// A column definition in a book. Mirrors Rust `Property`.
public struct PropertyFfi: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let propertyType: PropertyTypeFfi

    enum CodingKeys: String, CodingKey { case id, name, propertyType = "type_" }

    public init(id: String, name: String, propertyType: PropertyTypeFfi) {
        self.id = id
        self.name = name
        self.propertyType = propertyType
    }
}

/// Matches serde's externally-tagged representation of `PropertyValue`.
