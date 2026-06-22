import Foundation

// ── Typed FFI wrappers ───────────────────────────────────────────────────────
//
// UniFFI 0.31 can't express the recursive `Block`/`Leaf` types in the
// UDL, so the FFI ships JSON strings for the full leaf, full book,
// query results, deleted entries and entry search. Every call site used to
// repeat the decode dance:
//
//     guard let json = try? api.getLeafJson(id: leafId),
//           let data = json.data(using: .utf8),
//           let doc  = try? JSONDecoder().decode(LeafFfi.self, from: data)
//     else { return }
//
// These extensions hide that boilerplate behind a typed surface. The
// `*Json` siblings stay reachable on the underlying `PinkhaApi` for any
// caller that genuinely needs the raw JSON.

public extension PinkhaApi {
    /// Full leaf (with blocks) decoded from the JSON-returning FFI.
    public func getLeaf(id: String) throws -> LeafFfi {
        let json = try getLeafJson(id: id)
        return try LeafFfi.decode(fromJson: json)
    }

    /// Full book (with entries and views) decoded from the JSON-returning FFI.
    public func getBook(id: String) throws -> BookFfi {
        let json = try getBookJson(id: id)
        return try BookFfi.decode(fromJson: json)
    }

    /// Entries returned by a view query (filters + sorts applied server-side).
    public func queryBook(bookId: String, viewId: String) throws -> [EntryFfi] {
        let json = try queryBookJson(bookId: bookId, viewId: viewId)
        return try [EntryFfi].decode(fromJson: json)
    }

    /// Same as `queryBook` but with rollup columns computed at read time.
    public func queryBookWithRollups(bookId: String, viewId: String) throws -> [EntryFfi] {
        let json = try queryBookWithRollupsJson(bookId: bookId, viewId: viewId)
        return try [EntryFfi].decode(fromJson: json)
    }

    /// Case-insensitive search across the book's entries.
    public func searchBookEntries(bookId: String, query: String) throws -> [EntryFfi] {
        let json = try searchBookEntriesJson(bookId: bookId, query: query)
        return try [EntryFfi].decode(fromJson: json)
    }

    /// Trashed entries of a book (newest-deleted first).
    public func listDeletedEntries(bookId: String) throws -> [EntryFfi] {
        let json = try listDeletedEntriesJson(bookId: bookId)
        return try [EntryFfi].decode(fromJson: json)
    }

    /// Returns the view's entries bucketed by date. Empty array means
    /// the view has no `dateGrouping` configured ; callers should fall
    /// back to flat rendering. Pass `override` to preview a config
    /// without persisting it (e.g. from the config sheet).
    public func dateGroupedQuery(
        bookId: String,
        viewId: String,
        override: DateGroupingFfi? = nil
    ) throws -> [DateGroupNodeFfi] {
        let overrideJson: String
        if let override {
            let data = try JSONEncoder().encode(override)
            overrideJson = String(data: data, encoding: .utf8) ?? ""
        } else {
            overrideJson = ""
        }
        let json = try dateGroupedQueryBookJson(
            bookId: bookId,
            viewId: viewId,
            overrideGroupingJson: overrideJson
        )
        return try [DateGroupNodeFfi].decode(fromJson: json)
    }

    /// Persists a date-grouping config onto a view, or clears it when
    /// `grouping` is `nil`.
    public func setViewDateGrouping(
        bookId: String,
        viewId: String,
        grouping: DateGroupingFfi?
    ) throws {
        let json: String
        if let grouping {
            let data = try JSONEncoder().encode(grouping)
            json = String(data: data, encoding: .utf8) ?? ""
        } else {
            json = ""
        }
        try setViewDateGrouping(bookId: bookId, viewId: viewId, groupingJson: json)
    }
}

// ── Decode helper ────────────────────────────────────────────────────────────

/// Errors surfaced by the typed FFI wrappers. Always wraps a decode failure
/// in a `PinkhaError.Storage` so the existing error-alert path treats it as
/// a transient SQLite-style problem (the user can retry).
public enum TypedFfiError {
    /// Maps a JSON-decode failure to a `PinkhaError.Storage` with the
    /// underlying message — that variant is what `tryCatch` recognises as
    /// recoverable.
    public static func decodeFailure(_ underlying: Error, type: Any.Type) -> PinkhaError {
        .Storage(detail: "decode \(type): \(underlying.localizedDescription)")
    }
}

private extension Decodable {
    /// Decodes `Self` from a JSON `String`. Maps both bad UTF-8 and decode
    /// failures to `PinkhaError.Storage` so callers can route them through
    /// the existing `tryCatch(into:)` / `errorAlert` path.
    static func decode(fromJson json: String) throws -> Self {
        guard let data = json.data(using: .utf8) else {
            throw PinkhaError.Storage(detail: "decode \(Self.self): JSON is not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw TypedFfiError.decodeFailure(error, type: Self.self)
        }
    }
}
