import SwiftUI
import PinkhaCore

// ── Library row + date formatting ──────────────────────────────────────────

/// Shared ISO-to-relative-date helper used by `LibraryRow`,
/// `RecentCard` and `LeafCardPreview`. Kept at file scope so the
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
    public init(item: WorkspaceItem,
                displayDateIso: String? = nil,
                store: PinkhaStore? = nil) {
        self.item = item
        self.displayDateIso = displayDateIso
        self.store = store
    }
    public let item: WorkspaceItem
    /// ISO date shown under the title. Defaults to `updatedAt` (the
    /// historical behaviour) but callers can override — `LibraryView`
    /// passes `createdAt` when the user sorts by Created so the visible
    /// timestamp matches the active sort key.
    public var displayDateIso: String? = nil
    /// Optional store reference. When provided, leaves get a "Move to
    /// shelf…" context menu (long-press). Passed `nil` from contexts
    /// where the move action doesn't apply (e.g. UIKit hosting previews).
    public var store: PinkhaStore? = nil

    public var body: some View {
        rowContent
            .padding(.vertical, 2)
            // Drag&drop disabled : neither the new Transferable
            // `.dropDestination` nor the legacy `.onDrop` work reliably
            // inside a `List` on iOS (FB12980427), and a UIKit wrap
            // imposes too much rewrite. The long-press "Move to shelf…"
            // menu below covers the same intent.
            .modifier(LeafMoveMenuModifier(item: item, store: store))
    }

    @ViewBuilder
    private var rowContent: some View {
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
    }

    @ViewBuilder
    private var itemIcon: some View {
        switch item {
        case .leaf(let doc):
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

    /// Attaches a `Move to shelf…` long-press menu on leaves when a
    /// `store` is available. Books get nothing. The submenu lists every
    /// shelf — picking one calls `moveLeafToShelf`; picking "Library
    /// root" un-files the leaf.
    private struct LeafMoveMenuModifier: ViewModifier {
        let item: WorkspaceItem
        let store: PinkhaStore?

        func body(content: Content) -> some View {
            if case .leaf(let doc) = item, let store {
                content.contextMenu {
                    Menu {
                        Button {
                            store.moveLeafToShelf(leafId: doc.id, shelfId: nil)
                            store.load()
                        } label: {
                            Label("Library root", systemImage: "books.vertical.fill")
                        }
                        Divider()
                        let shelves = store.listShelves()
                        if shelves.isEmpty {
                            Text("No shelves yet")
                        } else {
                            ForEach(shelves, id: \.id) { shelf in
                                Button {
                                    store.moveLeafToShelf(leafId: doc.id, shelfId: shelf.id)
                                    store.load()
                                } label: {
                                    Label(shelf.name, systemImage: "books.vertical.fill")
                                }
                            }
                        }
                    } label: {
                        Label("Move to shelf…", systemImage: "arrow.uturn.right.circle")
                    }
                }
            } else {
                content
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
