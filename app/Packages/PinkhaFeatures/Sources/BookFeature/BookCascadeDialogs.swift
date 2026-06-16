import SwiftUI
import PinkhaFFI
import PinkhaCore

// ── Book delete / restore confirmation dialogs ────────────────────────────
//
// Deleting or restoring a book raises the same question every time:
// what about the pages filed inside it? These two modifiers stage the
// book in an optional binding and let the user pick — cascade (pages
// follow the book) or book-only. Shared between the Books
// home, the Notes home rows and the Trash so the vocabulary stays
// identical everywhere.

public extension View {
    /// Confirmation dialog for deleting `pending`. "…& its pages" routes
    /// through the cascade FFI (pages land in the trash with the
    /// book); "only" keeps the pages as standalone notes.
    func databaseDeleteDialog(
        pending: Binding<BookMetaFfi?>,
        store: PinkhaStore
    ) -> some View {
        confirmationDialog(
            "Delete book?",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { db in
            Button("Delete book & its pages", role: .destructive) {
                store.deleteBookCascade(id: db.id)
            }
            Button("Delete book only", role: .destructive) {
                store.deleteBook(id: db.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { db in
            Text("\"\(db.titlePlain.isEmpty ? String(localized: "Untitled") : db.titlePlain)\" — pages filed in this book can go to the trash with it, or stay as standalone notes.")
        }
    }

    /// Confirmation dialog for restoring `pending` from the trash.
    /// "…& its pages" also restores the trashed leaves its rows are
    /// backed by; "only" brings back just the book shell.
    func databaseRestoreDialog(
        pending: Binding<BookMetaFfi?>,
        store: PinkhaStore,
        onDone: @escaping () -> Void = {}
    ) -> some View {
        confirmationDialog(
            "Restore book?",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { db in
            Button("Restore book & its pages") {
                store.restoreBookCascade(id: db.id)
                onDone()
            }
            Button("Restore book only") {
                store.restoreBook(id: db.id)
                onDone()
            }
            Button("Cancel", role: .cancel) {}
        } message: { db in
            Text("\"\(db.titlePlain.isEmpty ? String(localized: "Untitled") : db.titlePlain)\" — pages deleted with this book can come back with it, or stay in the trash.")
        }
    }
}
