import Foundation
import SwiftUI

// Database property metadata: Aggregate, PropertyType, Property.

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
