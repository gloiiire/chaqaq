import SwiftUI

// ── Store ─────────────────────────────────────────────────────────────────────

@MainActor
final class ChaqaqStore: ObservableObject {
    @Published var documents: [DocumentMetaFfi] = []
    @Published var erreur: String?

    private var api: ChaqaqApi?

    func connecter() {
        guard api == nil else { return }
        do {
            let dir  = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let path = dir.appendingPathComponent("chaqaq.db").path
            api = try ChaqaqApi(cheminDb: path)
            charger()
        } catch {
            erreur = error.localizedDescription
        }
    }

    func charger() {
        do {
            documents = try api?.listerDocuments() ?? []
        } catch {
            erreur = error.localizedDescription
        }
    }

    func creer(titre: String) {
        do {
            _ = try api?.creerDocument(titre: titre)
            charger()
        } catch {
            erreur = error.localizedDescription
        }
    }

    func supprimer(id: String) {
        do {
            try api?.supprimerDocument(id: id)
            charger()
        } catch {
            erreur = error.localizedDescription
        }
    }
}

// ── Vue principale ────────────────────────────────────────────────────────────

struct ContentView: View {
    @StateObject private var store = ChaqaqStore()
    @State private var showingCreer = false
    @State private var nouveauTitre = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.documents.isEmpty {
                    ContentUnavailableView(
                        "Aucun document",
                        systemImage: "doc.text",
                        description: Text("Appuie sur + pour créer ton premier document.")
                    )
                } else {
                    List {
                        ForEach(store.documents, id: \.id) { doc in
                            DocumentRow(doc: doc)
                        }
                        .onDelete { indexSet in
                            for i in indexSet {
                                store.supprimer(id: store.documents[i].id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("chaqaq")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Nouveau document", systemImage: "square.and.pencil") {
                        showingCreer = true
                    }
                }
            }
            .sheet(isPresented: $showingCreer) {
                CreerDocumentSheet(titre: $nouveauTitre) {
                    store.creer(titre: nouveauTitre)
                    nouveauTitre = ""
                    showingCreer = false
                } onCancel: {
                    nouveauTitre = ""
                    showingCreer = false
                }
            }
            .alert("Erreur", isPresented: Binding(
                get: { store.erreur != nil },
                set: { if !$0 { store.erreur = nil } }
            )) {
                Button("OK") { store.erreur = nil }
            } message: {
                Text(store.erreur ?? "")
            }
        }
        .onAppear { store.connecter() }
    }
}

// ── Composants ────────────────────────────────────────────────────────────────

struct DocumentRow: View {
    let doc: DocumentMetaFfi

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(doc.titlePlain.isEmpty ? "Sans titre" : doc.titlePlain)
                .font(.body)
            if !doc.updatedAt.isEmpty {
                Text(doc.updatedAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct CreerDocumentSheet: View {
    @Binding var titre: String
    let onCreate: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titre du document", text: $titre)
                        .focused($focused)
                }
            }
            .navigationTitle("Nouveau document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") { onCreate() }
                        .disabled(titre.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }
}
