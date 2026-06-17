import SwiftUI
import PinkhaFFI
import PinkhaCore

// ── Shelf delete cascade dialog ───────────────────────────────────────────────
//
// Same shape as `databaseDeleteDialog(pending:store:)` from
// BookFeature : the caller owns a `@State pending: ShelfMetaFfi?`
// slot, every delete entry point assigns the shelf into it, and the
// dialog observes the binding via the `presenting:` overload.
//
// ⚠️ Placement matters : `confirmationDialog` cannot present from
// inside a `Section` (Section isn't a presentation surface). The
// modifier MUST sit on the `List` / `NavigationStack` root. Sources
// nested deeper (rows, Sections) bubble the request up via a closure.

public extension View {
    func shelfDeleteDialog(
        pending: Binding<ShelfMetaFfi?>,
        store: PinkhaStore
    ) -> some View {
        confirmationDialog(
            "Delete shelf?",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { shelf in
            Button("Delete shelf & its contents", role: .destructive) {
                _ = store.deleteShelfCascade(id: shelf.id)
            }
            Button("Delete shelf only", role: .destructive) {
                store.deleteShelf(id: shelf.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { shelf in
            let name = shelf.name.isEmpty ? String(localized: "Untitled") : shelf.name
            Text("\"\(name)\" — leaves and sub-shelves filed in this shelf can go to the trash with it, or stay alive (sub-shelves move to the parent, leaves move to the library root).")
        }
    }
}
