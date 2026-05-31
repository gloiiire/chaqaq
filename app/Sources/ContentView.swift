import SwiftUI

// ── Vue racine : layout 3 onglets ──────────────────────────────────────────────

/// Vue racine — trois onglets : Notes, Bases, Recherche.
struct ContentView: View {
    @StateObject private var store = PinkhaStore()

    var body: some View {
        TabView {
            Tab("Notes", systemImage: "note.text") {
                NotesHomeView(store: store)
            }
            Tab("Bases", systemImage: "tablecells") {
                DatabasesHomeView()
            }
            Tab("Recherche", systemImage: "magnifyingglass") {
                SearchView(store: store)
            }
        }
        .onAppear { store.connect() }
        .errorAlert(message: $store.errorMessage, onRetry: store.load)
    }
}

// ── Onglet 2 : Bases de données ───────────────────────────────────────────────

/// Placeholder pour l'onglet Bases (backend complet, UI à venir).
private struct DatabasesHomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "tablecells")
                    .font(.system(size: 52))
                    .foregroundStyle(.tertiary)
                VStack(spacing: 6) {
                    Text("Bases de données").font(.headline)
                    Text("Bientôt disponible.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Bases")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// ── Onglet 3 : Recherche ──────────────────────────────────────────────────────

/// Onglet Recherche : recherche en temps réel dans les titres de documents.
private struct SearchView: View {
    @ObservedObject var store: PinkhaStore
    @State private var query = ""

    private var results: [DocumentMetaFfi] {
        query.isEmpty ? [] : store.search(query: query)
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Label("Tape pour chercher", systemImage: "text.magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.top, 32)
                } else if results.isEmpty {
                    Text("Aucun résultat pour « \(query) »")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.top, 32)
                } else {
                    if let api = store.api {
                        ForEach(results, id: \.id) { doc in
                            NavigationLink(
                                destination: DocumentView(docId: doc.id, api: api,
                                                          onDisappear: store.load)
                            ) {
                                DocumentRow(doc: doc)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Recherche")
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Titres des notes…")
            .autocorrectionDisabled()
        }
    }
}
