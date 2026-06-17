import Foundation
import PinkhaFFI

/// A unified library item — either a leaf or a book. Used by the
/// home strip, search results, the tab switcher, and anything else
/// that needs to render leaves and books in the same surface.
public enum WorkspaceItem: Identifiable, Sendable {
    case leaf(LeafMetaFfi)
    case book(BookMetaFfi)

    public var id: String {
        switch self { case .leaf(let d): return d.id; case .book(let db): return db.id }
    }
    public var titlePlain: String {
        switch self { case .leaf(let d): return d.titlePlain; case .book(let db): return db.titlePlain }
    }
    public var updatedAt: String {
        switch self { case .leaf(let d): return d.updatedAt; case .book(let db): return db.updatedAt }
    }
    public var createdAt: String {
        switch self { case .leaf(let d): return d.createdAt; case .book(let db): return db.createdAt }
    }
    /// Effective publish date — manual override on the leaf when set,
    /// `createdAt` otherwise. Books don't yet have a publish
    /// override surface so they fall back to their createdAt.
    public var publishedAt: String {
        switch self {
        case .leaf(let d):
            return d.publishedAt.isEmpty ? d.createdAt : d.publishedAt
        case .book(let db):
            return db.createdAt
        }
    }
    public var isBook: Bool { if case .book = self { return true }; return false }
}
