import SwiftUI

// ── Store ─────────────────────────────────────────────────────────────────────

@MainActor
final class ChaqaqStore: ObservableObject {
    @Published var documents: [DocumentMetaFfi] = []
    @Published var erreur: String?

    private(set) var cheminDb: String = ""
    private var api: ChaqaqApi?

    func connecter() {
        guard api == nil else { return }
        do {
            let dir  = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let path = dir.appendingPathComponent("chaqaq.db").path
            cheminDb = path
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
            ZStack(alignment: .bottomTrailing) {
                List {
                    Section {
                        EnTeteBienvenue(salutation: salutation)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    if store.documents.isEmpty {
                        Section {
                            EtatVide()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    } else {
                        Section("Documents") {
                            ForEach(store.documents, id: \.id) { doc in
                                NavigationLink(destination: DocumentView(docId: doc.id, cheminDb: store.cheminDb)) {
                                    DocumentRow(doc: doc)
                                }
                            }
                            .onDelete { indexSet in
                                for i in indexSet {
                                    store.supprimer(id: store.documents[i].id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("chaqaq")
                .navigationBarTitleDisplayMode(.inline)

                BoutonCreer {
                    showingCreer = true
                }
                .padding(.trailing, 24)
                .padding(.bottom, 32)
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

    private var salutation: String {
        let h = Calendar.current.component(.hour, from: .now)
        switch h {
        case 5..<12: return "Bonjour."
        case 12..<18: return "Bon après-midi."
        default:      return "Bonsoir."
        }
    }
}

// ── Composants ────────────────────────────────────────────────────────────────

private struct EnTeteBienvenue: View {
    let salutation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(salutation)
                .font(.largeTitle.bold())
            Text("Tes notes, à toi.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EtatVide: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Aucun document")
                    .font(.headline)
                Text("Appuie sur le bouton en bas à droite\npour créer ta première note.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private struct BoutonCreer: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
                .background(.tint)
                .foregroundStyle(.white)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        }
    }
}

struct DocumentRow: View {
    let doc: DocumentMetaFfi

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(doc.titlePlain.isEmpty ? "Sans titre" : doc.titlePlain)
                .font(.body.weight(.medium))
            if let date = dateFormatee(doc.updatedAt) {
                Text(date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func dateFormatee(_ iso: String) -> String? {
        guard !iso.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
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
