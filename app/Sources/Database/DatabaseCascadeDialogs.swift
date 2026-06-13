import SwiftUI

// ── Database delete / restore confirmation dialogs ────────────────────────────
//
// Deleting or restoring a database raises the same question every time:
// what about the pages filed inside it? These two modifiers stage the
// database in an optional binding and let the user pick — cascade (pages
// follow the database) or database-only. Shared between the Databases
// home, the Notes home rows and the Trash so the vocabulary stays
// identical everywhere.

extension View {
    /// Confirmation dialog for deleting `pending`. "…& its pages" routes
    /// through the cascade FFI (pages land in the trash with the
    /// database); "only" keeps the pages as standalone notes.
    func databaseDeleteDialog(
        pending: Binding<DatabaseMetaFfi?>,
        store: PinkhaStore
    ) -> some View {
        confirmationDialog(
            "Delete database?",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { db in
            Button("Delete database & its pages", role: .destructive) {
                store.deleteDatabaseCascade(id: db.id)
            }
            Button("Delete database only", role: .destructive) {
                store.deleteDatabase(id: db.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { db in
            Text("\"\(db.titlePlain.isEmpty ? String(localized: "Untitled") : db.titlePlain)\" — pages filed in this database can go to the trash with it, or stay as standalone notes.")
        }
    }

    /// Confirmation dialog for restoring `pending` from the trash.
    /// "…& its pages" also restores the trashed documents its rows are
    /// backed by; "only" brings back just the database shell.
    func databaseRestoreDialog(
        pending: Binding<DatabaseMetaFfi?>,
        store: PinkhaStore,
        onDone: @escaping () -> Void = {}
    ) -> some View {
        confirmationDialog(
            "Restore database?",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { db in
            Button("Restore database & its pages") {
                store.restoreDatabaseCascade(id: db.id)
                onDone()
            }
            Button("Restore database only") {
                store.restoreDatabase(id: db.id)
                onDone()
            }
            Button("Cancel", role: .cancel) {}
        } message: { db in
            Text("\"\(db.titlePlain.isEmpty ? String(localized: "Untitled") : db.titlePlain)\" — pages deleted with this database can come back with it, or stay in the trash.")
        }
    }
}
