import SwiftUI

// ── Store ─────────────────────────────────────────────────────────────────────

@MainActor
final class ChaqaqStore: ObservableObject {
    @Published var documents: [DocumentMetaFfi] = []
    @Published var erreur: String?

    private(set) var api: ChaqaqApi?

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
                            if let api = store.api {
                                ForEach(store.documents, id: \.id) { doc in
                                    NavigationLink(destination: DocumentView(docId: doc.id, api: api, onDisparaitre: store.charger)) {
                                        DocumentRow(doc: doc)
                                    }
                                }
                                .onDelete { indexSet in
                                    for i in indexSet {
                                        store.supprimer(id: store.documents[i].id)
                                    }
                                }
                            } else {
                                ProgressView()
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
    @State private var impulsion = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.58)) {
                impulsion = true
            }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(.easeOut(duration: 0.18)) {
                    impulsion = false
                }
            }
        } label: {
            ZStack {
                if impulsion {
                    Circle()
                        .fill(Color("SelectionTint").opacity(0.18))
                        .frame(width: 54, height: 54)
                        .transition(.scale.combined(with: .opacity))
                }

                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .symbolEffect(.bounce, value: impulsion)
            }
            .frame(width: 54, height: 54)
            .contentShape(Circle())
        }
        .buttonStyle(BoutonCreerStyle())
        .sensoryFeedback(.impact(flexibility: .soft), trigger: impulsion)
    }
}

private struct BoutonCreerStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassEffect(.regular.interactive(), in: .circle)
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .rotationEffect(.degrees(configuration.isPressed ? -6 : 0))
            .shadow(color: Color("SelectionTint").opacity(configuration.isPressed ? 0.34 : 0.18),
                    radius: configuration.isPressed ? 20 : 12,
                    y: configuration.isPressed ? 8 : 6)
            .animation(.spring(response: 0.22, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

struct DocumentRow: View {
    let doc: DocumentMetaFfi

    var body: some View {
        HStack(spacing: 12) {
            iconeDocument

            VStack(alignment: .leading, spacing: 4) {
                Text(doc.titlePlain.isEmpty ? "Sans titre" : doc.titlePlain)
                    .font(.body.weight(.medium))
                if let date = dateFormatee(doc.updatedAt) {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var iconeDocument: some View {
        if let icone = UserDefaults.standard.string(forKey: Self.cleIcone(docId: doc.id)), !icone.isEmpty {
            Text(icone)
                .font(.title2)
                .frame(width: 34, height: 34)
        } else {
            Image(systemName: "doc.text")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private static func cleIcone(docId: String) -> String {
        "document.icon.\(docId)"
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
                        .submitLabel(.done)
                        .onSubmit {
                            guard !titre.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            onCreate()
                        }
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
