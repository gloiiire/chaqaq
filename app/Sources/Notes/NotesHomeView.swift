import SwiftUI

// ── Tab 1: Notes ──────────────────────────────────────────────────────────────

/// Notes tab home screen: greeting, recent strip, full list, FAB.
struct NotesHomeView: View {
    @ObservedObject var store: PinkhaStore
    @State private var showingCreate = false
    @State private var newTitle = ""

    /// The 5 most recently modified documents for the "Recent" strip.
    private var recentDocs: [DocumentMetaFfi] {
        Array(store.documents.prefix(5))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                List {
                    // ── Recent strip (only when documents exist) ─────────
                    if !store.documents.isEmpty {
                        Section {
                            RecentStrip(docs: recentDocs, api: store.api) {
                                store.load()
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                        } header: {
                            SectionHeader(title: "Recent")
                        }
                    }

                    // ── Full list ────────────────────────────────────────
                    if store.documents.isEmpty {
                        Section {
                            NotesEmptyState()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    } else {
                        Section {
                            if let api = store.api {
                                ForEach(store.documents, id: \.id) { doc in
                                    NavigationLink(
                                        destination: DocumentView(docId: doc.id, api: api,
                                                                  onDisappear: store.load)
                                    ) {
                                        DocumentRow(doc: doc)
                                    }
                                }
                                .onDelete { indexSet in
                                    for i in indexSet { store.delete(id: store.documents[i].id) }
                                }
                            } else {
                                ProgressView()
                            }
                        } header: {
                            SectionHeader(title: "All notes")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(greeting)
                .navigationBarTitleDisplayMode(.large)

                FloatingButton(icon: "square.and.pencil") {
                    showingCreate = true
                }
                .accessibilityIdentifier("createDocumentFAB")
                .padding(.trailing, 24)
                .padding(.bottom, 32)
            }
            .sheet(isPresented: $showingCreate) {
                CreateDocumentSheet(title: $newTitle) {
                    store.create(title: newTitle)
                    newTitle = ""
                    showingCreate = false
                } onCancel: {
                    newTitle = ""
                    showingCreate = false
                }
            }
        }
    }

    /// Returns a greeting message adapted to the time of day.
    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        switch h {
        case 5..<12: return "Good morning."
        case 12..<18: return "Good afternoon."
        default:      return "Good evening."
        }
    }
}

// ── Recent strip ──────────────────────────────────────────────────────────────

/// Horizontal scroll strip displaying the most recent documents as cards.
struct RecentStrip: View {
    let docs: [DocumentMetaFfi]
    let api: PinkhaApi?
    let onDisappear: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(docs, id: \.id) { doc in
                    if let api {
                        NavigationLink(destination: DocumentView(docId: doc.id, api: api,
                                                                 onDisappear: onDisappear)) {
                            RecentCard(doc: doc)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
    }
}

/// A card in the recent strip — displays icon, title, and relative date.
struct RecentCard: View {
    let doc: DocumentMetaFfi

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let icon = storedIcon, !icon.isEmpty {
                    Text(icon).font(.title)
                } else {
                    Image(systemName: "doc.text").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)

            Spacer()

            VStack(alignment: .leading, spacing: 3) {
                Text(doc.titlePlain.isEmpty ? "Untitled" : doc.titlePlain)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let date = formattedDate(doc.updatedAt) {
                    Text(date).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .frame(width: 150, height: 140)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var storedIcon: String? {
        UserDefaults.standard.string(forKey: "document.icon.\(doc.id)")
    }

    private func formattedDate(_ iso: String) -> String? {
        guard !iso.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
