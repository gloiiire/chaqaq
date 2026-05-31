import SwiftUI

// ── Root view: 3-tab layout ──────────────────────────────────────────────────

/// Root view — three tabs: Notes, Databases, Search.
struct ContentView: View {
    @StateObject private var store = PinkhaStore()

    var body: some View {
        TabView {
            Tab("Notes", systemImage: "note.text") {
                NotesHomeView(store: store)
            }
            Tab(role: .search) {
                SearchView(store: store)
            }
        }
        .onAppear { store.connect() }
        .errorAlert(message: $store.errorMessage, onRetry: store.load)
    }
}

// ── Tab 2: Search ─────────────────────────────────────────────────────────────

/// Search tab — owns its own .searchable so it does not bleed into other tabs.
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
                    Label("Type to search", systemImage: "text.magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.top, 32)
                } else if results.isEmpty {
                    Text("No results for \"\(query)\"")
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
                                WorkspaceRow(item: .note(doc))
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Note titles…")
            .autocorrectionDisabled()
        }
    }
}
