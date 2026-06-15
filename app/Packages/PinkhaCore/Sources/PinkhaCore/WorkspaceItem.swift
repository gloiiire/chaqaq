import Foundation
import PinkhaFFI

/// A unified workspace item — either a note or a database. Used by the
/// home strip, search results, the tab switcher, and anything else
/// that needs to render notes and databases in the same surface.
public enum WorkspaceItem: Identifiable, Sendable {
    case note(DocumentMetaFfi)
    case database(DatabaseMetaFfi)

    public var id: String {
        switch self { case .note(let d): return d.id; case .database(let db): return db.id }
    }
    public var titlePlain: String {
        switch self { case .note(let d): return d.titlePlain; case .database(let db): return db.titlePlain }
    }
    public var updatedAt: String {
        switch self { case .note(let d): return d.updatedAt; case .database(let db): return db.updatedAt }
    }
    public var createdAt: String {
        switch self { case .note(let d): return d.createdAt; case .database(let db): return db.createdAt }
    }
    /// Effective publish date — manual override on the doc when set,
    /// `createdAt` otherwise. Databases don't yet have a publish
    /// override surface so they fall back to their createdAt.
    public var publishedAt: String {
        switch self {
        case .note(let d):
            return d.publishedAt.isEmpty ? d.createdAt : d.publishedAt
        case .database(let db):
            return db.createdAt
        }
    }
    public var isDatabase: Bool { if case .database = self { return true }; return false }
}
