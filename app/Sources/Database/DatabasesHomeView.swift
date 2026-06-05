import SwiftUI

// ── Tab 2: Databases ──────────────────────────────────────────────────────────

/// Home screen for the Databases tab — lists all databases. Creation is
/// global, hosted by `ContentView`'s create bubble accessory; this view
/// keeps only the list, the empty state and the destructive overflow.
struct DatabasesHomeView: View {
    @ObservedObject var store: PinkhaStore

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
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            store.deleteDatabase(id: db.id)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .tint(.red)
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
