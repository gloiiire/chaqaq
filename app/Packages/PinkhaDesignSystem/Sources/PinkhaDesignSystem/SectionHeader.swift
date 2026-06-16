import SwiftUI

/// Section header in uppercase with semi-bold caption style.
///
/// `title` is a `LocalizedStringKey` so the string is resolved via
/// `Localizable.xcstrings` (instead of `String`, which SwiftUI treats
/// as a literal and never localizes). The visual uppercase comes from
/// `.textCase(.uppercase)` — applying `.uppercased()` to the raw String
/// would bypass the catalog lookup.
public struct SectionHeader: View {
    public init(title: LocalizedStringKey) { self.title = title }
    public let title: LocalizedStringKey

    public var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
            .textCase(.uppercase)
    }
}
