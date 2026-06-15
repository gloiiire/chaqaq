import Foundation
import SwiftUI

// Database — full payload with rows and views.

public struct DatabaseFfi: Codable {
    public let id: String
    public let title: [InlineTextFfi]
    /// Optional banner image identifier — URL or local filename. Mirrors
    /// the document cover surface so the doc-like DB header can render
    /// one. Decoded explicitly because Codable synthesis won't accept a
    /// missing key without an explicit `init(from:)`.
    public var cover: String?
    /// Optional emoji / filename / URL displayed next to the title.
    public var icon: String?
    /// Rich-text description shown under the title in the header. Empty
    /// means "no description".
    public var description: [InlineTextFfi]
    public let properties: [PropertyFfi]
    public var entries: [EntryFfi]
    /// At least one view is always present (Rust `Database::new` seeds a
    /// default "List" view). `#[serde(default)]` would keep us safe against
    /// older payloads — Codable's Optional support gives the same guarantee.
    public let views: [ViewFfi]?

    /// Read-only flag. Mirrors `Document.locked` ; defaults `false`
    /// when missing so old payloads stay decodable.
    public var locked: Bool

    /// UUID of the Date property driving every row's publish date, or
    /// `nil` when publish dates follow `created_at`. Mirrors
    /// `Database.published_at_source`.
    public var publishedAtSource: String?

    enum CodingKeys: String, CodingKey {
        case id, title, cover, icon, description, locked, properties, entries, views
        case publishedAtSource = "published_at_source"
    }

    public init(from decoder: Decoder) throws {
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
        publishedAtSource = try c.decodeIfPresent(String.self, forKey: .publishedAtSource)
    }

    public init(
        id: String,
        title: [InlineTextFfi],
        cover: String? = nil,
        icon: String? = nil,
        description: [InlineTextFfi] = [],
        locked: Bool = false,
        properties: [PropertyFfi],
        entries: [EntryFfi],
        views: [ViewFfi]? = nil,
        publishedAtSource: String? = nil
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
        self.publishedAtSource = publishedAtSource
    }
}

/// View layout discriminator. Mirrors the Rust `ViewType` externally-tagged
/// serde encoding. `List` and `Table` and `Gallery` are unit variants ;
