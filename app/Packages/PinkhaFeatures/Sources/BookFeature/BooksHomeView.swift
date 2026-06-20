import SwiftUI
import PinkhaFFI
import PinkhaCore
import PinkhaDesignSystem

// ── Tab 2: Books ──────────────────────────────────────────────────────────

/// Home screen for the Books tab — lists all books. Creation is
/// global, hosted by `ContentView`'s create bubble accessory; this view
/// keeps only the list, the empty state and the destructive overflow.
public struct BooksHomeView: View {
    /// Book awaiting the delete confirmation dialog — swiping Delete
    /// stages the row here instead of deleting straight away so the user
    /// chooses whether the pages inside go with it.
    @State private var pendingDeletion: BookMetaFfi?

    @Bindable public var store: PinkhaStore

    public init(store: PinkhaStore) {
        self.store = store
    }
    /// Apple-Music-style zoom transition source ; the destination
    /// `BookView` pairs it with `.navigationTransition(.zoom(...))`
    /// so opening a row reads as the card expanding into the editor.
    /// Same surface as `LibraryView.docZoom`.
    @Namespace private var dbZoom

    public var body: some View { 
        NavigationStack {
            List {
                    if store.books.isEmpty {
                        Section {
                            BooksEmptyState()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    } else {
                        Section {
                            if let api = store.api {
                                ForEach(store.books, id: \.id) { db in
                                    NavigationLink(destination:
                                        BookView(bookId: db.id, api: api,
                                                     onDisappear: store.load)
                                            .navigationTransition(.zoom(sourceID: db.id, in: dbZoom))
                                    ) {
                                        BookRow(db: db)
                                    }
                                    .matchedTransitionSource(id: db.id, in: dbZoom)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            pendingDeletion = db
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
                            SectionHeader(title: "All books")
                        }
                    }
                }
            .listStyle(.insetGrouped)
            .navigationTitle("Books")
            .navigationBarTitleDisplayMode(.large)
            // iOS 26 : soft edge fade under the large nav title and the tab
            // accessory bar — matches the Library home and the system look.
            .scrollEdgeEffectStyle(.soft, for: .all)
            .databaseDeleteDialog(pending: $pendingDeletion, store: store)
        }
    }
}

// ── Row ───────────────────────────────────────────────────────────────────────

private struct BookRow: View {
    let db: BookMetaFfi

    public var body: some View {
        HStack(spacing: 12) {
            iconView
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if db.titlePlain.isEmpty { Text("Untitled") } else { Text(db.titlePlain) }
                }
                    .font(.body.weight(.medium))
                if let date = formattedDate(db.updatedAt) {
                    Text(date).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    /// Renders the book's icon — the emoji glyph when one was
    /// imported / picked, else the built-in tablecells placeholder.
    @ViewBuilder
    private var iconView: some View {
        if let icon = db.icon, !icon.isEmpty {
            Text(icon)
                .font(.title2)
                .frame(width: 34, height: 34)
        } else {
            Image(systemName: "book")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.secondary.opacity(0.12),
                             in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func formattedDate(_ iso: String) -> String? {
        guard let date = parsePinkhaDate(iso) else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

// ── Empty state ───────────────────────────────────────────────────────────────

private struct BooksEmptyState: View {
    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "book")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("No books").font(.headline)
                Text("Tap the button at the bottom right\nto create your first book.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
