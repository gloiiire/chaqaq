import SwiftUI
import PinkhaFFI
import PinkhaCore

/// Single-property `Identifiable` wrapper for `.sheet(item:)` bindings
/// driven by a leaf id. Lives here (and not nested inside `LibraryView`)
/// so it can be re-used by every screen that surfaces the "Add to a
/// book" / "Bind to a book" sheet — `ShelfView`, `RecentStrip`, and the
/// PINNED section all need it.
public struct BindLeafIdentifier: Identifiable, Equatable {
    public let id: String
    public init(id: String) { self.id = id }
}

// ── Shared leaf context menu ──────────────────────────────────────────────────
//
// One source of truth for the long-press menu attached to a leaf row,
// regardless of where the row lives (Library "All" section, Pinned
// section, Shelf view, etc.). Builds: Rename → Pin/Unpin → Add to a
// book → Move to shelf… → Delete. Use via:
//
//     NavigationLink(destination: …) { LibraryRow(item: .leaf(doc), store: store) }
//         .leafContextMenu(doc: doc, store: store,
//                          onRename: { … }, onAttachToBook: { … })

public extension View {
    @ViewBuilder
    func leafContextMenu(
        doc: LeafMetaFfi,
        store: PinkhaStore,
        onRename: @escaping () -> Void,
        onAttachToBook: (() -> Void)? = nil
    ) -> some View {
        self.contextMenu {
            LeafContextMenuContent(
                doc: doc,
                store: store,
                onRename: onRename,
                onAttachToBook: onAttachToBook
            )
        }
    }
}

/// Long-press menu content for a leaf row. Extracted to a struct so it
/// can sit inside `.contextMenu { … }` without exploding the SwiftUI
/// type-checker on bigger surrounding views.
public struct LeafContextMenuContent: View {
    let doc: LeafMetaFfi
    @Bindable var store: PinkhaStore
    let onRename: () -> Void
    let onAttachToBook: (() -> Void)?

    public init(doc: LeafMetaFfi,
                store: PinkhaStore,
                onRename: @escaping () -> Void,
                onAttachToBook: (() -> Void)? = nil) {
        self.doc = doc
        self.store = store
        self.onRename = onRename
        self.onAttachToBook = onAttachToBook
    }

    public var body: some View {
        // ⚠️ Per-button `.tint(.primary)` (and `.tint(.red)` on the
        // destructive action) is the established Pinkha norm for menu
        // icons — without it iOS paints the SF Symbols in the
        // surrounding TabView accent (blue / orange / whatever the
        // user picked in Settings). The earlier `.foregroundStyle()`
        // on the Label didn't propagate to icons inside a `Menu`.
        Button {
            onRename()
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .tint(.primary)
        Button {
            withAnimation {
                let isPinned = (doc.pinnedAt ?? "").isEmpty == false
                store.setLeafPinned(leafId: doc.id, pinned: !isPinned)
            }
        } label: {
            if (doc.pinnedAt ?? "").isEmpty {
                Label("Pin", systemImage: "pin")
            } else {
                Label("Unpin", systemImage: "pin.slash")
            }
        }
        .tint(.primary)
        if let onAttachToBook, !store.books.isEmpty {
            Button {
                onAttachToBook()
            } label: {
                Label("Add to a book", systemImage: "tablecells.badge.ellipsis")
            }
            .tint(.primary)
        }
        // Move to shelf… — same submenu as in the Library / Pinned
        // long-press, so the affordance is uniform across surfaces.
        Menu {
            Button {
                withAnimation {
                    store.moveLeafToShelf(leafId: doc.id, shelfId: nil)
                }
            } label: {
                Label("Library root", systemImage: "books.vertical.fill")
            }
            .tint(.primary)
            Divider()
            let shelves = store.listShelves()
            if shelves.isEmpty {
                Text("No shelves yet")
            } else {
                ForEach(shelves, id: \.id) { shelf in
                    Button {
                        withAnimation {
                            store.moveLeafToShelf(leafId: doc.id, shelfId: shelf.id)
                        }
                    } label: {
                        Label(shelf.name, systemImage: "books.vertical.fill")
                    }
                    .tint(.primary)
                }
            }
        } label: {
            Label("Move to shelf…", systemImage: "arrow.uturn.right.circle")
        }
        .tint(.primary)
        Divider()
        Button(role: .destructive) {
            withAnimation {
                store.delete(id: doc.id)
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .tint(.red)
    }
}
