import SwiftUI

// ── Vue racine : layout 3 onglets ──────────────────────────────────────────────

/// Vue racine — trois onglets : Notes, Bases, Recherche.
struct ContentView: View {
    @StateObject private var store = PinkhaStore()
    @State private var searchQuery = ""

    var body: some View {
        TabView {
            Tab("Notes", systemImage: "note.text") {
                NotesHomeView(store: store)
            }
            Tab("Bases", systemImage: "tablecells") {
                DatabasesHomeView()
            }
            Tab(role: .search) {
                SearchView(store: store, query: searchQuery)
            }
        }
        .searchable(text: $searchQuery, prompt: "Titres des notes…")
        .autocorrectionDisabled()
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

/// Onglet Recherche — la query vient du .searchable posé sur le TabView.
private struct SearchView: View {
    @ObservedObject var store: PinkhaStore
    let query: String

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
        }
    }
}
