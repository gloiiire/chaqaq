import Foundation

/// Filesystem helpers for cover-image storage. These are pure path
/// utilities, not tied to any view model, so they live at the
/// PinkhaCore layer where every consumer (Notes home, Leaf
/// editor, DesignSystem CoverImageView) can reach them.
public enum CoverImageStorage {
    /// Storage directory for cover images. Created on first call so
    /// the writer can land straight into it.
    public static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Pinkha/Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `data` for the given doc and returns the short filename
    /// to persist on the meta row. Slashes in `leafId` are flattened
    /// since the on-disk filename can't carry them.
    @discardableResult
    public static func write(data: Data, leafId: String, fileExtension: String) throws -> String {
        let directory = try directory()
        let name = leafId.replacingOccurrences(of: "/", with: "-") + "." + fileExtension
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return name
    }

    /// Normalizes a file extension to one of the supported cover
    /// image formats. Anything outside the allow-list maps to "jpg"
    /// — matches the JPEG that PhotosPicker hands us by default.
    public static func normalizeExtension(_ ext: String) -> String {
        let cleaned = ext.lowercased()
        return ["jpg", "jpeg", "png", "heic", "webp"].contains(cleaned) ? cleaned : "jpg"
    }
}
