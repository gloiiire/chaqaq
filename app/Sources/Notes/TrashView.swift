import SwiftUI

/// Trash view — shows soft-deleted documents, databases, and folders with
/// per-item restore / delete-forever actions plus a global "Empty Trash" button.
///
/// Items here are recoverable until the user explicitly purges them (manual
/// purge only — no auto-purge is wired up). Backed by the Rust FFI
/// `list_deleted_*` / `restore_*` / `purge_*` calls exposed via PinkhaStore.
struct TrashView: View {
    @EnvironmentObject private var store: PinkhaStore
    @State private var deletedDocs: [DocumentMetaFfi] = []
    @State private var deletedDatabases: [DatabaseMetaFfi] = []
    @State private var deletedFolders: [FolderMetaFfi] = []
    @State private var showEmptyConfirm = false

    private var totalCount: Int {
        deletedDocs.count + deletedDatabases.count + deletedFolders.count
    }

    var body: some View {
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
            .toolbar {
                if totalCount > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            showEmptyConfirm = true
                        } label: {
                            Text("Empty")
                        }
                    }
                }
            }
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
            .onAppear(perform: reload)
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView(
            "Trash is empty",
            systemImage: "trash",
            description: Text("Deleted notes, databases and folders will appear here.")
        )
    }

    private var list: some View {
        List {
            if !deletedDocs.isEmpty {
                Section("Notes") {
                    ForEach(deletedDocs, id: \.id) { doc in
                        rowDoc(doc)
                    }
                }
            }
            if !deletedDatabases.isEmpty {
                Section("Databases") {
                    ForEach(deletedDatabases, id: \.id) { db in
                        rowDatabase(db)
                    }
                }
            }
            if !deletedFolders.isEmpty {
                Section("Folders") {
                    ForEach(deletedFolders, id: \.id) { folder in
                        rowFolder(folder)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func rowDoc(_ doc: DocumentMetaFfi) -> some View {
        TrashRow(
            title: doc.titlePlain.isEmpty ? "Untitled" : doc.titlePlain,
            icon: "doc.text",
            onRestore: {
                store.restoreDocument(id: doc.id)
                reload()
            },
            onPurge: {
                store.purgeDocument(id: doc.id)
                reload()
            }
        )
    }

    private func rowDatabase(_ db: DatabaseMetaFfi) -> some View {
        TrashRow(
            title: db.titlePlain.isEmpty ? "Untitled" : db.titlePlain,
            icon: "tablecells",
            onRestore: {
                store.restoreDatabase(id: db.id)
                reload()
            },
            onPurge: {
                store.purgeDatabase(id: db.id)
                reload()
            }
        )
    }

    private func rowFolder(_ folder: FolderMetaFfi) -> some View {
        TrashRow(
            title: folder.name,
            icon: "folder",
            onRestore: {
                store.restoreFolder(id: folder.id)
                reload()
            },
            onPurge: {
                store.purgeFolder(id: folder.id)
                reload()
            }
        )
    }

    private func reload() {
        deletedDocs = store.listDeletedDocuments()
        deletedDatabases = store.listDeletedDatabases()
        deletedFolders = store.listDeletedFolders()
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

    var body: some View {
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
