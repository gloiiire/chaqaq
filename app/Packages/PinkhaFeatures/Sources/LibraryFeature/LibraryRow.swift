import SwiftUI
import PinkhaCore

// ── Library row + date formatting ──────────────────────────────────────────

/// Shared ISO-to-relative-date helper used by `LibraryRow`,
/// `RecentCard` and `NoteCardPreview`. Kept at file scope so the
/// UIKit hosting controller (in `UIKitContextMenu`) can reuse it
/// without instantiating the surrounding struct.
func formattedRelativeDate(_ iso: String) -> String? {
    guard !iso.isEmpty else { return nil }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = parser.date(from: iso) else { return nil }
    return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
}

/// A row in the unified library list.
public struct LibraryRow: View {
    public init(item: WorkspaceItem, displayDateIso: String? = nil) {
        self.item = item
        self.displayDateIso = displayDateIso
    }
    public let item: WorkspaceItem
    /// ISO date shown under the title. Defaults to `updatedAt` (the
    /// historical behaviour) but callers can override — `LibraryView`
    /// passes `createdAt` when the user sorts by Created so the visible
    /// timestamp matches the active sort key.
    public var displayDateIso: String? = nil

    public var body: some View {
        HStack(spacing: 12) {
            itemIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(item.titlePlain.isEmpty ? "Untitled" : item.titlePlain)
                    .font(.body.weight(.medium))
                if let date = formattedDate(displayDateIso ?? item.updatedAt) {
                    Text(date).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var itemIcon: some View {
        switch item {
        case .note(let doc):
            if let icon = doc.icon, !icon.isEmpty {
                Text(icon).font(.title2).frame(width: 34, height: 34)
            } else {
                Image(systemName: "doc.text")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(.secondary.opacity(0.12),
                                 in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        case .book(let db):
            if let icon = db.icon, !icon.isEmpty {
                Text(icon).font(.title2).frame(width: 34, height: 34)
            } else {
                Image(systemName: "tablecells")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(.secondary.opacity(0.12),
                                 in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    /// Row uses the wide units style (e.g. "3 minutes ago") for readability,
    /// in contrast to `formattedRelativeDate` which uses abbreviated.
    private func formattedDate(_ iso: String) -> String? {
        guard !iso.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}
