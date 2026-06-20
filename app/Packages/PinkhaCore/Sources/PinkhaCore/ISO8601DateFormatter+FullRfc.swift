import Foundation

public extension ISO8601DateFormatter {
    /// Shared RFC 3339 formatter — matches the format Rust's
    /// `chrono::Utc::now().to_rfc3339()` produces, so round-tripping a
    /// Date through Swift ↔ Rust stays stable. Used wherever Pinkha
    /// writes a fresh `published_at`, `created_at`, or `updated_at`.
    nonisolated(unsafe) static let fullRfc: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Tolerant RFC 3339 / ISO 8601 date parser shared by every view that
/// displays a `created_at` / `updated_at` / `published_at` value.
///
/// Three passes :
///   1. `withInternetDateTime` + `withFractionalSeconds` — the chrono
///      output (`…45.123456+00:00`).
///   2. `withInternetDateTime` alone — Notion's `created_time` style
///      (`…45.000Z` works either way, bare `…45Z` only here).
///   3. `yyyy-MM-dd` — Notion Date *property* values can be date-only
///      strings ; `ISO8601DateFormatter` refuses them outright. Mainly
///      reaches the home view when a `published_at_source` column
///      propagates a date-only cell to the leaf's `published_at`.
///
/// Returns `nil` only when the string genuinely doesn't match any
/// known shape — empty strings and pure garbage included.
public func parsePinkhaDate(_ iso: String) -> Date? {
    guard !iso.isEmpty else { return nil }
    if let date = ISO8601DateFormatter.fullRfc.date(from: iso) { return date }
    let withoutMs = ISO8601DateFormatter()
    withoutMs.formatOptions = [.withInternetDateTime]
    if let date = withoutMs.date(from: iso) { return date }
    let bare = DateFormatter()
    bare.locale = Locale(identifier: "en_US_POSIX")
    bare.timeZone = TimeZone(secondsFromGMT: 0)
    bare.dateFormat = "yyyy-MM-dd"
    return bare.date(from: iso)
}
