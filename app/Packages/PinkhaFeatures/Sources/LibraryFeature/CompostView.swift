import SwiftUI
import PinkhaFFI
import PinkhaCore

/// Trash view — shows soft-deleted leaves, books, and shelves with
/// per-item restore / delete-forever actions plus a global "Empty Trash" button.
///
/// Items here are recoverable until the user explicitly purges them (manual
/// purge only — no auto-purge is wired up). Backed by the Rust FFI
/// `list_deleted_*` / `restore_*` / `purge_*` calls exposed via PinkhaStore.
public struct TrashView: View {
    public init() {}
    @Environment(PinkhaStore.self) private var store
    @State private var deletedDocs: [LeafMetaFfi] = []
    @State private var deletedBooks: [BookMetaFfi] = []
    @State private var deletedShelves: [ShelfMetaFfi] = []
    @State private var showEmptyConfirm = false
    /// Multi-select state. `editMode` toggles via the Select button;
    /// `selectedIds` collects the chosen rows across all three sections
    /// — the id-space is unified at the FFI level so a single Set is
    /// enough to drive both Restore and Delete-Forever in bulk.
    @State private var editMode: EditMode = .inactive
    @State private var selectedIds: Set<String> = []
    @State private var showBulkPurgeConfirm = false
    /// Book staged for the restore confirmation dialog — the user
    /// decides whether its trashed pages come back with it.
    @State private var pendingBookRestore: BookMetaFfi?

    private var totalCount: Int {
        deletedDocs.count + deletedBooks.count + deletedShelves.count
    }

    public var body: some View {
        NavigationStack {
            Group {
                if totalCount == 0 {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Trash")
            .navigationBarTitleDisplayMode(.large)
            .environment(\.editMode, $editMode)
            .toolbar {
                if totalCount > 0 && editMode != .active {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Select") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                editMode = .active
                            }
                        }
                        .tint(.primary)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            showEmptyConfirm = true
                        } label: {
                            Text("Empty")
                        }
                    }
                }
                if editMode == .active {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                editMode = .inactive
                                selectedIds.removeAll()
                            }
                        }
                        .tint(.primary)
                    }
                    // Restore on the trailing side (the recoverable
                    // action), Delete-forever on the bottom-bar's
                    // safer-feeling secondary slot.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            restoreSelected()
                        } label: {
                            Label(
                                selectedIds.isEmpty ? "Restore" : "Restore (\(selectedIds.count))",
                                systemImage: "arrow.uturn.backward"
                            )
                        }
                        .tint(.primary)
                        .disabled(selectedIds.isEmpty)
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Spacer()
                        Button(role: .destructive) {
                            showBulkPurgeConfirm = true
                        } label: {
                            Label(
                                selectedIds.isEmpty ? "Delete forever" : "Delete forever (\(selectedIds.count))",
                                systemImage: "trash"
                            )
                        }
                        .tint(.red)
                        .disabled(selectedIds.isEmpty)
                    }
                }
            }
            .databaseRestoreDialog(pending: $pendingBookRestore, store: store, onDone: reload)
            .confirmationDialog(
                "Empty the trash?",
                isPresented: $showEmptyConfirm,
                titleVisibility: .visible
            ) {
                Button("Empty permanently", role: .destructive) {
                    let _ = store.emptyTrash()
                    reload()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(totalCount) item(s) will be permanently removed.")
            }
            // Confirmation guards the bulk Delete-forever — restore
            // is non-destructive so it acts immediately without prompt.
            .confirmationDialog(
                "Delete \(selectedIds.count) item\(selectedIds.count == 1 ? "" : "s") forever?",
                isPresented: $showBulkPurgeConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete forever", role: .destructive) { purgeSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This action cannot be undone.")
            }
            .onAppear(perform: reload)
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView(
            "Trash is empty",
            systemImage: "trash",
            description: Text("Deleted leaves, books and shelves will appear here.")
        )
    }

    private var list: some View {
        List(selection: $selectedIds) {
            if !deletedDocs.isEmpty {
                Section("Leaves") {
                    ForEach(deletedDocs, id: \.id) { doc in
                        rowDoc(doc)
                    }
                }
            }
            if !deletedBooks.isEmpty {
                Section("Books") {
                    ForEach(deletedBooks, id: \.id) { db in
                        rowBook(db)
                    }
                }
            }
            if !deletedShelves.isEmpty {
                Section("Shelves") {
                    ForEach(deletedShelves, id: \.id) { shelf in
                        rowShelf(shelf)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func rowDoc(_ doc: LeafMetaFfi) -> some View {
        TrashRow(
            title: doc.titlePlain.isEmpty ? "Untitled" : doc.titlePlain,
            icon: "doc.text",
            onRestore: {
                store.restoreLeaf(id: doc.id)
                reload()
            },
            onPurge: {
                store.purgeLeaf(id: doc.id)
                reload()
            }
        )
    }

    private func rowBook(_ db: BookMetaFfi) -> some View {
        TrashRow(
            title: db.titlePlain.isEmpty ? "Untitled" : db.titlePlain,
            icon: "tablecells",
            onRestore: {
                // Stage the dialog — the user picks whether the pages
                // deleted alongside the book come back with it.
                pendingBookRestore = db
            },
            onPurge: {
                store.purgeBook(id: db.id)
                reload()
            }
        )
    }

    private func rowShelf(_ shelf: ShelfMetaFfi) -> some View {
        TrashRow(
            title: shelf.name,
            icon: "shelf",
            onRestore: {
                store.restoreShelf(id: shelf.id)
                reload()
            },
            onPurge: {
                store.purgeShelf(id: shelf.id)
                reload()
            }
        )
    }

    private func reload() {
        deletedDocs = store.listDeletedLeaves()
        deletedBooks = store.listDeletedBooks()
        deletedShelves = store.listDeletedShelves()
    }

    /// Bulk restore — partitions `selectedIds` by which list they
    /// belong to (docs / books / shelves) and routes each through
    /// its matching FFI call. Selection is cleared BEFORE the FFI
    /// calls so SwiftUI's List doesn't try to diff an update where
    /// the selection still references rows about to disappear (avoids
    /// the same `NSInternalInconsistencyException` family as APPLE-
    /// IOS-8 on the home view).
    private func restoreSelected() {
        let leafIds = deletedDocs.map(\.id).filter(selectedIds.contains)
        let bookIds  = deletedBooks.map(\.id).filter(selectedIds.contains)
        let fIds   = deletedShelves.map(\.id).filter(selectedIds.contains)
        clearSelectionAndExitEdit()
        store.restoreItems(leafIds: leafIds, bookIds: bookIds, shelfIds: fIds)
        reload()
    }

    /// Bulk permanent delete — same partition + clear-before-mutate
    /// strategy as restore. Guarded by the confirmationDialog above;
    /// never called directly from the toolbar tap.
    private func purgeSelected() {
        let leafIds = deletedDocs.map(\.id).filter(selectedIds.contains)
        let bookIds  = deletedBooks.map(\.id).filter(selectedIds.contains)
        let fIds   = deletedShelves.map(\.id).filter(selectedIds.contains)
        clearSelectionAndExitEdit()
        store.purgeItems(leafIds: leafIds, bookIds: bookIds, shelfIds: fIds)
        reload()
    }

    private func clearSelectionAndExitEdit() {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedIds.removeAll()
            editMode = .inactive
        }
    }
}

/// A single trashed-item row with icon, title, and inline Restore / Delete-
/// forever actions exposed via swipe and a contextual menu (long-press).
private struct TrashRow: View {
    let title: String
    let icon: String
    let onRestore: () -> Void
    let onPurge: () -> Void

    @State private var showPurgeConfirm = false

    public var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(title)
                .lineLimit(1)
            Spacer()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                showPurgeConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
            Button {
                onRestore()
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                onRestore()
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                showPurgeConfirm = true
            } label: {
                Label("Delete forever", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete forever?",
            isPresented: $showPurgeConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete forever", role: .destructive) {
                onPurge()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }
}
