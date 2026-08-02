import Foundation

/// Resolves where `pinkha.db` lives on disk, and moves it out of the
/// user-visible Documents folder on first launch after the relocation.
///
/// ## Why it moved
///
/// The database holds every note the user has ever written, in plaintext
/// SQLite. It used to sit in `Documents/`, and `Info.plist` declares
/// `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` — which
/// exposes that folder in the Files app under "On My iPhone → Pinkha" and
/// over desktop file sharing to any trusted-paired Mac. Anyone with brief
/// physical access to an unlocked device could copy the whole library out,
/// with no passcode re-prompt and no share sheet.
///
/// Application Support is not user-visible and is the documented home for
/// app-managed data the user doesn't manipulate directly. `CoverImageStorage`
/// already lives there — this brings the database in line.
///
/// ## Why not `NSFileProtectionComplete`
///
/// Tempting, but it would make the file unreadable whenever the device is
/// locked, and SQLite in WAL mode keeps handles open. Any background wake
/// would fail hard. The default protection class
/// (`CompleteUntilFirstUserAuthentication`) plus a non-shared directory is
/// the right trade here.
public enum DatabaseLocation {
    private static let fileName = "pinkha.db"

    /// SQLite writes two sidecar files next to the database in WAL mode.
    /// A relocation that moves only the `.db` silently drops every write
    /// that is committed to the log but not yet checkpointed.
    private static let sidecarSuffixes = ["-wal", "-shm"]

    /// The directory the database lives in: `Application Support/Pinkha/`.
    /// Created on first call.
    public static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Pinkha", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Path to the production database, relocating a pre-existing one out of
    /// `Documents/` if this is the first launch since the move.
    public static func databasePath() throws -> String {
        let destination = try directory().appendingPathComponent(fileName)
        try migrateFromDocumentsIfNeeded(to: destination)
        purgeLegacyDebugArtifacts()
        return destination.path
    }

    /// Removes note-content-bearing artefacts that earlier builds left in the
    /// user-visible Documents folder.
    ///
    /// Release builds no longer produce `notion-debug.log` (see
    /// `extractors::notion::diagnostics`), but a user who ran an older build
    /// already has one sitting in Files.app with their note titles and
    /// paragraph text in it. Fixing the writer doesn't clean up after it.
    private static func purgeLegacyDebugArtifacts() {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        try? fm.removeItem(at: documents.appendingPathComponent("notion-debug.log"))
    }

    /// Path for an ephemeral UI-test database. Kept in the same directory so
    /// tests exercise the real code path, but with a throwaway name.
    public static func ephemeralDatabasePath() throws -> String {
        try directory()
            .appendingPathComponent("pinkha_uitest_\(UUID().uuidString).db")
            .path
    }

    /// Moves a legacy `Documents/pinkha.db` (and its WAL sidecars) to
    /// `destination`, once.
    ///
    /// No-ops when there is nothing to move, or when a database already
    /// exists at the destination — in that case the destination is
    /// authoritative and the legacy file is left alone rather than
    /// clobbering live data. Uses `moveItem` so the operation is atomic per
    /// file and the originals never linger in the user-visible folder.
    private static func migrateFromDocumentsIfNeeded(to destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return }
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }

        let legacy = documents.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: legacy.path) else { return }

        // Main file first: if this throws, the sidecars stay put next to a
        // database that is still where the app will look for it on retry.
        try fm.moveItem(at: legacy, to: destination)

        // Sidecars are best-effort — SQLite rebuilds them from the main
        // file, so a missing one costs at most the un-checkpointed tail
        // rather than the whole library. Failing the launch over it would
        // be the worse outcome.
        //
        // A stale sidecar can already sit at the destination (an earlier
        // launch that created the directory, or a crash mid-migration).
        // `moveItem` refuses to overwrite, so clear the way first —
        // destination sidecars are meaningless once the main file they
        // describe is being replaced by the one arriving from Documents.
        let destinationDir = destination.deletingLastPathComponent()
        for suffix in sidecarSuffixes {
            let from = documents.appendingPathComponent(fileName + suffix)
            let to = destinationDir.appendingPathComponent(fileName + suffix)
            guard fm.fileExists(atPath: from.path) else {
                try? fm.removeItem(at: to)
                continue
            }
            try? fm.removeItem(at: to)
            try? fm.moveItem(at: from, to: to)
            // Whatever happened, don't leave note-bearing bytes behind in
            // the user-visible folder — that's the whole point of the move.
            try? fm.removeItem(at: from)
        }
    }
}
