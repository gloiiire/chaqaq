import Foundation

public extension ISO8601DateFormatter {
    /// Shared RFC 3339 formatter — matches the format Rust's
    /// `chrono::Utc::now().to_rfc3339()` produces, so round-tripping a
    /// Date through Swift ↔ Rust stays stable. Used wherever Pinkha
    /// reads/writes `published_at`, `created_at`, `updated_at` on
    /// leaves or books.
    nonisolated(unsafe) static let fullRfc: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
