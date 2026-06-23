import Foundation

// ── Date grouping mirrors ────────────────────────────────────────────────────
//
// Swift mirrors of the Rust `DateGrouping`, `DateGroupingSource`,
// `DateGranularity` and `DateGroupNode` types. They cross the FFI as
// JSON strings (UniFFI 0.31 doesn't model recursive types) ; these
// `Codable` structs hide the encode/decode dance behind a typed surface.

/// What the grouping picks as the per-entry date.
public enum DateGroupingSourceFfi: Codable, Equatable {
    /// Auto-generated `created_at`.
    case created
    /// User-editable `published_at` (falls back to `created_at` when blank).
    case published
    /// Value of the given Date property. Empty / missing cells fall
    /// into the "No date" bucket.
    case property(propertyId: String)

    private enum K: String, CodingKey { case Created, Published, Property }

    public init(from decoder: Decoder) throws {
        if let sv = try? decoder.singleValueContainer(),
           let s = try? sv.decode(String.self) {
            if s == "Created" { self = .created; return }
            if s == "Published" { self = .published; return }
        }
        let c = try decoder.container(keyedBy: K.self)
        if let id = try? c.decode(String.self, forKey: .Property) {
            self = .property(propertyId: id)
            return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath,
                  debugDescription: "Unknown DateGroupingSource"))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .created:
            var c = encoder.singleValueContainer()
            try c.encode("Created")
        case .published:
            var c = encoder.singleValueContainer()
            try c.encode("Published")
        case .property(let id):
            var c = encoder.container(keyedBy: K.self)
            try c.encode(id, forKey: .Property)
        }
    }
}

/// How fine-grained the buckets are. `yearMonth` is the only
/// hierarchical variant (year header > month children).
public enum DateGranularityFfi: String, Codable, Equatable {
    case year      = "Year"
    case month     = "Month"
    case yearMonth = "YearMonth"
    case day       = "Day"
}

/// Date-grouping config attached to a [`ViewFfi`]. `nil` on the view
/// means flat rendering.
public struct DateGroupingFfi: Codable, Equatable {
    public var source: DateGroupingSourceFfi
    public var granularity: DateGranularityFfi
    /// `false` = newest first (calendar-style default).
    public var ascending: Bool

    public init(source: DateGroupingSourceFfi,
                granularity: DateGranularityFfi,
                ascending: Bool = false) {
        self.source = source
        self.granularity = granularity
        self.ascending = ascending
    }
}

/// One bucket in the date-grouping tree. `labelYear == nil` is the
/// "No date" bucket ; `children` is non-empty only when granularity is
/// `yearMonth` (year nodes carry month children, no entries).
public struct DateGroupNodeFfi: Codable, Identifiable {
    public var labelYear: Int?
    public var labelMonth: Int?
    public var labelDay: Int?
    public var entries: [EntryFfi]
    public var children: [DateGroupNodeFfi]

    public init(labelYear: Int?,
                labelMonth: Int?,
                labelDay: Int?,
                entries: [EntryFfi],
                children: [DateGroupNodeFfi]) {
        self.labelYear = labelYear
        self.labelMonth = labelMonth
        self.labelDay = labelDay
        self.entries = entries
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case labelYear  = "label_year"
        case labelMonth = "label_month"
        case labelDay   = "label_day"
        case entries
        case children
    }

    /// Stable identifier for SwiftUI `ForEach`. Encodes year-month-day
    /// plus the "no date" sentinel so collisions are impossible.
    public var id: String {
        let y = labelYear.map(String.init) ?? "ND"
        let m = labelMonth.map(String.init) ?? "-"
        let d = labelDay.map(String.init) ?? "-"
        return "\(y)/\(m)/\(d)"
    }

    /// Total entries reachable from this node, recursing into children
    /// for `yearMonth` headers.
    public var totalEntries: Int {
        if children.isEmpty { return entries.count }
        return children.reduce(0) { $0 + $1.totalEntries }
    }
}
