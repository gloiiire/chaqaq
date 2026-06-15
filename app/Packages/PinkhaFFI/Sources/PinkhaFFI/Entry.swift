import Foundation
import SwiftUI

// Entry — one row in a book.

public struct EntryFfi: Codable, Identifiable {
    public let id: String
    public let createdAt: String
    /// User-editable publish timestamp. Defaults to `createdAt` at
    /// insert on the Rust side, so untouched entries behave
    /// identically. Empty string on legacy entries (pre-field) is
    /// treated as "fall back to createdAt" by the query path.
    public var publishedAt: String

    /// Whether the entry's publish date has been manually overridden
    /// (i.e. differs from `createdAt`). Used by the UI to show a
    /// little "scheduled" indicator next to the date.
    public var hasCustomPublishDate: Bool {
        !publishedAt.isEmpty && publishedAt != createdAt
    }

    /// Effective publish date — manual override when set, else
    /// `createdAt`. Mirrors the Rust query's fallback logic so the
    /// row's displayed date matches the column the user sorted by.
    public var effectivePublishedAt: String {
        publishedAt.isEmpty ? createdAt : publishedAt
    }
    public var values: [String: PropertyValueFfi]
    public let leafId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case publishedAt = "published_at"
        case values
        case leafId = "leaf_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        createdAt   = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        publishedAt = (try? c.decode(String.self, forKey: .publishedAt)) ?? ""
        values      = try c.decode([String: PropertyValueFfi].self, forKey: .values)
        leafId  = try c.decodeIfPresent(String.self, forKey: .leafId)
    }

    public init(
        id: String,
        createdAt: String,
        publishedAt: String = "",
        values: [String: PropertyValueFfi],
        leafId: String?
    ) {
        self.id          = id
        self.createdAt   = createdAt
        self.publishedAt = publishedAt
        self.values      = values
        self.leafId  = leafId
    }
}
