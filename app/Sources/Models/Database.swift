import Foundation
import SwiftUI

// Database — full payload with rows and views.

struct DatabaseFfi: Codable {
    let id: String
    let title: [InlineTextFfi]
    /// Optional banner image identifier — URL or local filename. Mirrors
    /// the document cover surface so the doc-like DB header can render
    /// one. Decoded explicitly because Codable synthesis won't accept a
    /// missing key without an explicit `init(from:)`.
    var cover: String?
    /// Optional emoji / filename / URL displayed next to the title.
    var icon: String?
    /// Rich-text description shown under the title in the header. Empty
    /// means "no description".
    var description: [InlineTextFfi]
    let properties: [PropertyFfi]
    var entries: [EntryFfi]
    /// At least one view is always present (Rust `Database::new` seeds a
    /// default "List" view). `#[serde(default)]` would keep us safe against
    /// older payloads — Codable's Optional support gives the same guarantee.
    let views: [ViewFfi]?

    /// Read-only flag. Mirrors `Document.locked` ; defaults `false`
    /// when missing so old payloads stay decodable.
    var locked: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, cover, icon, description, locked, properties, entries, views
    }

    init(from decoder: Decoder) throws {
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
    }

    init(
        id: String,
        title: [InlineTextFfi],
        cover: String? = nil,
        icon: String? = nil,
        description: [InlineTextFfi] = [],
        locked: Bool = false,
        properties: [PropertyFfi],
        entries: [EntryFfi],
        views: [ViewFfi]? = nil
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
    }
}

/// View layout discriminator. Mirrors the Rust `ViewType` externally-tagged
/// serde encoding. `List` and `Table` and `Gallery` are unit variants ;
