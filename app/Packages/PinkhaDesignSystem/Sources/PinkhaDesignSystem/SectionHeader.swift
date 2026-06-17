import SwiftUI

/// Section header in sentence case with semi-bold caption style —
/// "Recent" / "Pinned" / "Shelves" instead of the previous full
/// UPPERCASE. The string source in code already starts capitalized,
/// so we just suppress any `.textCase(.uppercase)` inherited from
/// the surrounding `List` style by pinning `.textCase(nil)`.
///
/// `title` is a `LocalizedStringKey` so the string is resolved via
/// `Localizable.xcstrings` (instead of `String`, which SwiftUI treats
/// as a literal and never localizes).
public struct SectionHeader: View {
    public init(title: LocalizedStringKey) { self.title = title }
    public let title: LocalizedStringKey

    public var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.3)
            .textCase(nil)
    }
}
