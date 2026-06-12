import SwiftUI

// ── Shared components ─────────────────────────────────────────────────────────

/// Section header in uppercase with semi-bold caption style.
///
/// `title` is a `LocalizedStringKey` so the string is resolved via
/// `Localizable.xcstrings` (instead of `String`, which SwiftUI treats
/// as a literal and never localizes). The visual uppercase comes from
/// `.textCase(.uppercase)` — applying `.uppercased()` to the raw String
/// would bypass the catalog lookup.
struct SectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
            .textCase(.uppercase)
    }
}

/// Greeting displayed at the top of the Notes tab.
struct GreetingHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.largeTitle.bold())
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Placeholder shown when there are no documents yet.
struct NotesEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("No notes").font(.headline)
                Text("Tap the button at the bottom right\nto create your first note.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
