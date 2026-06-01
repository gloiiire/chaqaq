import SwiftUI

// ── Tab 2: Databases ──────────────────────────────────────────────────────────

/// Home screen for the Databases tab — lists all databases with create/delete/import.
struct DatabasesHomeView: View {
    @ObservedObject var store: PinkhaStore
    @State private var showingCreate = false
    @State private var showingImport = false
    @State private var showingDeleteAllConfirm = false
    @State private var showingDeleteAllConfirm2 = false
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                List {
                    if store.databases.isEmpty {
                        Section {
                            DatabasesEmptyState()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    } else {
                        Section {
                            if let api = store.api {
                                ForEach(store.databases, id: \.id) { db in
                                    NavigationLink(destination: DatabaseView(dbId: db.id, api: api)) {
                                        DatabaseRow(db: db)
                                    }
                                }
                                .onDelete { indexSet in
                                    for i in indexSet {
                                        store.deleteDatabase(id: store.databases[i].id)
                                    }
                                }
                            } else {
                                ProgressView()
                            }
                        } header: {
                            SectionHeader(title: "All databases")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("Databases")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if !store.databases.isEmpty {
                            Button(role: .destructive) {
                                showingDeleteAllConfirm = true
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }

                // ── FAB ───────────────────────────────────────────────────
                Menu {
                    Button {
                        newTitle = ""
                        showingCreate = true
                    } label: {
                        Label("New database", systemImage: "tablecells.badge.ellipsis")
                    }
                    Divider()
                    Button {
                        showingImport = true
                    } label: {
                        Label("Import from Notion", systemImage: "arrow.down.doc")
                    }
                } label: {
                    FloatingButton(icon: "tablecells.badge.ellipsis") {}
                }
                .accessibilityIdentifier("createDatabaseFAB")
                .padding(.trailing, 24)
                .padding(.bottom, 32)
            }
            .sheet(isPresented: $showingCreate) {
                CreateDocumentSheet(
                    title: $newTitle,
                    prompt: "Database title"
                ) {
                    store.createDatabase(title: newTitle)
                    newTitle = ""
                    showingCreate = false
                } onCancel: {
                    newTitle = ""
                    showingCreate = false
                }
            }
            .sheet(isPresented: $showingImport) {
                NotionImportView(api: store.api) {
                    store.load()
                }
            }
        }
        .alert("Delete all \(store.databases.count) databases?", isPresented: $showingDeleteAllConfirm) {
            Button("Delete All", role: .destructive) {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    showingDeleteAllConfirm2 = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all your databases.")
        }
        .alert("Are you sure?", isPresented: $showingDeleteAllConfirm2) {
            Button("Yes, delete everything", role: .destructive) { store.deleteAllDatabases() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}

// ── Row ───────────────────────────────────────────────────────────────────────

private struct DatabaseRow: View {
    let db: DatabaseMetaFfi

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tablecells")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.secondary.opacity(0.12),
                             in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(db.titlePlain.isEmpty ? "Untitled" : db.titlePlain)
                    .font(.body.weight(.medium))
                if let date = formattedDate(db.updatedAt) {
                    Text(date).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func formattedDate(_ iso: String) -> String? {
        guard !iso.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

// ── Empty state ───────────────────────────────────────────────────────────────

private struct DatabasesEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tablecells")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("No databases").font(.headline)
                Text("Tap the button at the bottom right\nto create your first database.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
