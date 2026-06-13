import Foundation

// ── Typed FFI wrappers ───────────────────────────────────────────────────────
//
// UniFFI 0.31 can't express the recursive `Block`/`Document` types in the
// UDL, so the FFI ships JSON strings for the full document, full database,
// query results, deleted entries and entry search. Every call site used to
// repeat the decode dance:
//
//     guard let json = try? api.getDocumentJson(id: docId),
//           let data = json.data(using: .utf8),
//           let doc  = try? JSONDecoder().decode(DocumentFfi.self, from: data)
//     else { return }
//
// These extensions hide that boilerplate behind a typed surface. The
// `*Json` siblings stay reachable on the underlying `PinkhaApi` for any
// caller that genuinely needs the raw JSON.

extension PinkhaApi {
    /// Full document (with blocks) decoded from the JSON-returning FFI.
    func getDocument(id: String) throws -> DocumentFfi {
        let json = try getDocumentJson(id: id)
        return try DocumentFfi.decode(fromJson: json)
    }

    /// Full database (with entries and views) decoded from the JSON-returning FFI.
    func getDatabase(id: String) throws -> DatabaseFfi {
        let json = try getDatabaseJson(id: id)
        return try DatabaseFfi.decode(fromJson: json)
    }

    /// Entries returned by a view query (filters + sorts applied server-side).
    func queryDatabase(dbId: String, viewId: String) throws -> [EntryFfi] {
        let json = try queryDatabaseJson(dbId: dbId, viewId: viewId)
        return try [EntryFfi].decode(fromJson: json)
    }

    /// Same as `queryDatabase` but with rollup columns computed at read time.
    func queryDatabaseWithRollups(dbId: String, viewId: String) throws -> [EntryFfi] {
        let json = try queryDatabaseWithRollupsJson(dbId: dbId, viewId: viewId)
        return try [EntryFfi].decode(fromJson: json)
    }

    /// Case-insensitive search across the database's entries.
    func searchDatabaseEntries(dbId: String, query: String) throws -> [EntryFfi] {
        let json = try searchDatabaseEntriesJson(dbId: dbId, query: query)
        return try [EntryFfi].decode(fromJson: json)
    }

    /// Trashed entries of a database (newest-deleted first).
    func listDeletedEntries(dbId: String) throws -> [EntryFfi] {
        let json = try listDeletedEntriesJson(dbId: dbId)
        return try [EntryFfi].decode(fromJson: json)
    }
}

// ── Decode helper ────────────────────────────────────────────────────────────

/// Errors surfaced by the typed FFI wrappers. Always wraps a decode failure
/// in a `PinkhaError.Storage` so the existing error-alert path treats it as
/// a transient SQLite-style problem (the user can retry).
enum TypedFfiError {
    /// Maps a JSON-decode failure to a `PinkhaError.Storage` with the
    /// underlying message — that variant is what `tryCatch` recognises as
    /// recoverable.
    static func decodeFailure(_ underlying: Error, type: Any.Type) -> PinkhaError {
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
