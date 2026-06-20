import Foundation
import SwiftUI

// View, ViewType, Sort + GenericKey helper.

public enum ViewTypeFfi: Equatable {
    case list
    case table
    case kanban(groupBy: String)
    case calendar(propertyId: String)
    case gallery

    public var systemImage: String {
        switch self {
        case .list:     return "list.bullet"
        case .table:    return "tablecells"
        case .kanban:   return "rectangle.split.3x1"
        case .calendar: return "calendar"
        case .gallery:  return "square.grid.2x2"
        }
    }

    public var label: LocalizedStringKey {
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
    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
    public var stringValue: String
    public var intValue: Int? { nil }
    public init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Swift mirror of Rust `View`. Only the fields the UI consumes today.
public struct ViewFfi: Codable, Identifiable {
    public let id: String
    public let name: String
    /// `type_` on Rust side ; `type` on Swift side (reserved word — gets
    /// renamed via CodingKeys). Drives which view component renders.
    public var type: ViewTypeFfi = .list
    public let sorts: [SortFfi]
    /// Optional date-grouping config. `nil` = flat rendering.
    public let dateGrouping: DateGroupingFfi?

    enum CodingKeys: String, CodingKey {
        case id, name
        case type = "type_"
        case sorts
        case dateGrouping = "date_grouping"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(String.self, forKey: .id)
        name         = try c.decode(String.self, forKey: .name)
        type         = (try? c.decode(ViewTypeFfi.self, forKey: .type)) ?? .list
        sorts        = (try? c.decode([SortFfi].self, forKey: .sorts)) ?? []
        dateGrouping = try? c.decode(DateGroupingFfi?.self, forKey: .dateGrouping)
    }

    public init(id: String,
                name: String,
                type: ViewTypeFfi = .list,
                sorts: [SortFfi] = [],
                dateGrouping: DateGroupingFfi? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.sorts = sorts
        self.dateGrouping = dateGrouping
    }
}

/// Swift mirror of Rust `Sort`. `order` is `"Ascending"` / `"Descending"`,
/// `source` is `"Property"` / `"Created"` / `"ManualThenCreated"` — match the
/// serde externally-tagged enum encoding.
public struct SortFfi: Codable, Equatable {
    public let propertyId: String
    public let order: String
    public let source: String

    enum CodingKeys: String, CodingKey {
        case propertyId = "property_id"
        case order
        case source
    }
}
