import SwiftUI

public extension Color {
    /// Builds a colour from a packed `0xRRGGBB` literal.
    ///
    /// Exists because the reader themes are transcribed from values extracted
    /// out of Apple Books, where they are documented and compared as hex.
    /// Writing them back as `Color(red: 0.290196, green: 0.290196, ...)` would
    /// make every future diff against
    /// `utilities/docs/BOOKS-READER-SETTINGS-RE.md` an arithmetic exercise,
    /// and rounding drift would creep in unnoticed.
    ///
    /// Deliberately in `PinkhaCore` and not the design system: `AppSettings`
    /// needs it, and Core cannot depend on `PinkhaDesignSystem` — the
    /// dependency runs the other way.
    ///
    /// Always opaque; the themes have no alpha component.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: 1
        )
    }
}
