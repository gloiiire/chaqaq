import SwiftUI

// ── Tab 2: Databases ──────────────────────────────────────────────────────────

/// Home screen for the Databases tab — lists all databases. Creation is
/// global, hosted by `ContentView`'s create bubble accessory; this view
/// keeps only the list, the empty state and the destructive overflow.
struct DatabasesHomeView: View {
    @ObservedObject var store: PinkhaStore
    @State private var showingDeleteAllConfirm = false
    @State private var showingDeleteAllConfirm2 = false

    var body: some View {
        NavigationStack {
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
                                    NavigationLink(destination: DatabaseView(dbId: db.id, api: api,
                                                                            onDisappear: store.load)) {
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
