import Foundation

/// Per-leaf style overrides the user picks on the creation sheet
/// when the new note is NOT being filed in a book — cover, icon,
/// theme, optional backdated publish date, optional custom cover
/// bytes. Promoted out of `CreateLeafSheet` so the cross-domain
/// `PinkhaStore+Composer` extension (which lives in the Library
/// feature) can hand it to the FFI without dragging the entire
/// sheet view into its scope.
public struct StandaloneStyle: Equatable {
    public var cover: String? = nil
    public var icon: String? = nil
    public var theme: String? = nil
    /// Optional RFC 3339 timestamp used to backdate the new doc's
    /// `published_at`. `nil` = the SQLite store falls back to the
    /// row's `created_at` (default behaviour). Set when the user
    /// pre-picks a publish date on the creation sheet.
    public var publishedAt: String? = nil
    /// Raw bytes of a user-picked cover image (PhotosPicker or
    /// fileImporter). `nil` = no custom cover ; the gradient catalogue
    /// in `cover` is used as-is. When set, the store writes the bytes
    /// into the covers directory once the leafId is known and replaces
    /// `cover` with the resulting filename — keeps the SQLite contract
    /// (cover is a short string) without leaking image bytes into the
    /// meta row.
    public var customCoverData: Data? = nil
    /// File extension to use when persisting `customCoverData`. Defaults
    /// to `"jpg"` ; PhotosPicker normalises to JPEG when reading via
    /// `loadTransferable(type: Data.self)`, fileImporter preserves the
    /// original (`heic`, `png`, …).
    public var customCoverExt: String = "jpg"

    public init(
        cover: String? = nil,
        icon: String? = nil,
        theme: String? = nil,
        publishedAt: String? = nil,
        customCoverData: Data? = nil,
        customCoverExt: String = "jpg"
    ) {
        self.cover = cover
        self.icon = icon
        self.theme = theme
        self.publishedAt = publishedAt
        self.customCoverData = customCoverData
        self.customCoverExt = customCoverExt
    }
}
