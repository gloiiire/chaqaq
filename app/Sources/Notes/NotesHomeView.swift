import SwiftUI

// ── Onglet 1 : Notes ──────────────────────────────────────────────────────────

/// Écran d'accueil de l'onglet Notes : salutation, strip récents, liste complète, FAB.
struct NotesHomeView: View {
    @ObservedObject var store: PinkhaStore
    @State private var showingCreate = false
    @State private var newTitle = ""

    /// Les 5 documents les plus récemment modifiés pour la strip "Récents".
    private var recentDocs: [DocumentMetaFfi] {
        Array(store.documents.prefix(5))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                List {
                    // ── Strip récents (uniquement quand des documents existent) ──
                    if !store.documents.isEmpty {
                        Section {
                            RecentStrip(docs: recentDocs, api: store.api) {
                                store.load()
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                        } header: {
                            SectionHeader(title: "Récents")
                        }
                    }

                    // ── Liste complète ────────────────────────────────────
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
                            SectionHeader(title: "Toutes les notes")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(greeting)

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

    /// Retourne un message de salutation adapté à l'heure de la journée.
    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        switch h {
        case 5..<12: return "Bonjour."
        case 12..<18: return "Bon après-midi."
        default:      return "Bonsoir."
        }
    }
}

// ── Strip récents ──────────────────────────────────────────────────────────────

/// Bande de défilement horizontal affichant les documents les plus récents sous forme de cartes.
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

/// Une carte de la strip récents — affiche icône, titre et date relative.
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
                Text(doc.titlePlain.isEmpty ? "Sans titre" : doc.titlePlain)
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
