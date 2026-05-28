import SwiftUI

// ── Modèle éditable ───────────────────────────────────────────────────────────

struct EditableBlock: Identifiable {
    let id: String
    var content: BlockContentFfi
    var texte: String
    var done: Bool
}

// ── View Model ────────────────────────────────────────────────────────────────

@MainActor
final class DocumentViewModel: ObservableObject {
    let docId: String
    @Published var titre: String = ""
    @Published var blocs: [EditableBlock] = []
    @Published var erreur: String?
    @Published var autoFocusId: String?

    private var api: ChaqaqApi?

    init(docId: String, cheminDb: String) {
        self.docId = docId
        do { api = try ChaqaqApi(cheminDb: cheminDb) }
        catch { erreur = error.localizedDescription }
    }

    func charger() {
        guard let api else { return }
        do {
            let json = try api.obtenirDocumentJson(id: docId)
            guard let data = json.data(using: .utf8) else { return }
            let doc = try JSONDecoder().decode(DocumentFfi.self, from: data)
            titre = doc.title.map(\.content).joined()
            blocs = doc.blocks.map {
                EditableBlock(id: $0.id, content: $0.content,
                              texte: $0.content.texteSimple,
                              done: $0.content.doneTodo)
            }
        } catch { erreur = error.localizedDescription }
    }

    func sauvegarderTitre() {
        guard let api, !titre.isEmpty else { return }
        try? api.modifierTitreDocument(id: docId, nouveauTitre: titre)
    }

    func sauvegarderBloc(_ bloc: EditableBlock) {
        guard let api else { return }
        do {
            let nouveau = bloc.content.avecTexte(bloc.texte, done: bloc.done)
            let data = try JSONEncoder().encode(nouveau)
            try api.modifierBloc(docId: docId, blocId: bloc.id,
                                 contenuJson: String(data: data, encoding: .utf8)!)
        } catch { erreur = error.localizedDescription }
    }

    func ajouterBloc(type: TypeBlocNouvel, texteInitial: String = "", apresId: String? = nil) {
        guard let api else { return }
        do {
            let contenu: BlockContentFfi
            switch type {
            case .texte:      contenu = .text([])
            case .titre1:     contenu = .heading(level: 1, text: [])
            case .titre2:     contenu = .heading(level: 2, text: [])
            case .titre3:     contenu = .heading(level: 3, text: [])
            case .citation:   contenu = .quote(icon: "", text: [])
            case .todo:       contenu = .todo(done: false, text: [])
            case .separateur: contenu = .divider
            }
            let data = try JSONEncoder().encode(contenu)
            let newId = try api.ajouterBloc(docId: docId,
                                            blocContentJson: String(data: data, encoding: .utf8)!)

            var newBloc = EditableBlock(id: newId, content: contenu,
                                       texte: texteInitial, done: false)

            if let apresId, let idx = blocs.firstIndex(where: { $0.id == apresId }) {
                blocs.insert(newBloc, at: idx + 1)
                try? api.reordonnerBlocs(docId: docId, ordre: blocs.map(\.id))
            } else {
                blocs.append(newBloc)
            }

            if !texteInitial.isEmpty { sauvegarderBloc(newBloc) }
            autoFocusId = newId
        } catch { erreur = error.localizedDescription }
    }

    func supprimerBloc(id: String) {
        guard let api else { return }
        do {
            try api.supprimerBloc(docId: docId, blocId: id)
            blocs.removeAll { $0.id == id }
        } catch { erreur = error.localizedDescription }
    }

    func deplacerBloc(from: IndexSet, to: Int) {
        blocs.move(fromOffsets: from, toOffset: to)
        guard let api else { return }
        try? api.reordonnerBlocs(docId: docId, ordre: blocs.map(\.id))
    }
}

// ── Types de blocs ────────────────────────────────────────────────────────────

enum TypeBlocNouvel: String, CaseIterable, Identifiable {
    case texte = "Texte", titre1 = "Titre 1", titre2 = "Titre 2", titre3 = "Titre 3"
    case citation = "Citation", todo = "À faire", separateur = "Séparateur"
    var id: String { rawValue }
    var icone: String {
        switch self {
        case .texte:      return "text.alignleft"
        case .titre1:     return "1.circle.fill"
        case .titre2:     return "2.circle"
        case .titre3:     return "3.circle"
        case .citation:   return "quote.bubble"
        case .todo:       return "checkmark.square"
        case .separateur: return "minus"
        }
    }
}

// ── Vue document ──────────────────────────────────────────────────────────────

struct DocumentView: View {
    @StateObject private var vm: DocumentViewModel
    @State private var showingBlocPicker = false
    @State private var editMode: EditMode = .inactive

    init(docId: String, cheminDb: String) {
        _vm = StateObject(wrappedValue: DocumentViewModel(docId: docId, cheminDb: cheminDb))
    }

    var body: some View {
        List {
            TitreDocView(titre: $vm.titre, onSauvegarder: vm.sauvegarderTitre)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
                .moveDisabled(true)
                .deleteDisabled(true)

            if vm.blocs.isEmpty {
                Text("Commence à écrire…")
                    .foregroundStyle(.tertiary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .moveDisabled(true)
                    .deleteDisabled(true)
            }

            ForEach($vm.blocs) { $bloc in
                BlocRowView(
                    bloc: $bloc,
                    autoFocusId: $vm.autoFocusId,
                    onSauvegarder: { vm.sauvegarderBloc(bloc) },
                    onSupprimer:   { vm.supprimerBloc(id: bloc.id) },
                    onNouveauBloc: { apres in
                        vm.ajouterBloc(type: .texte, texteInitial: apres, apresId: bloc.id)
                    }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { vm.supprimerBloc(id: bloc.id) } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                }
            }
            .onMove(perform: vm.deplacerBloc)

            BoutonAjouterBloc { showingBlocPicker = true }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 40, trailing: 20))
                .moveDisabled(true)
                .deleteDisabled(true)
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationTitle(vm.titre.isEmpty ? "Sans titre" : vm.titre)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                } label: {
                    Image(systemName: editMode == .active ? "checkmark" : "arrow.up.arrow.down")
                }
            }
        }
        .onAppear { vm.charger() }
        .onDisappear { vm.sauvegarderTitre() }
        .sheet(isPresented: $showingBlocPicker) {
            BlocPickerSheet { type in vm.ajouterBloc(type: type) }
        }
        .alert("Erreur", isPresented: Binding(
            get: { vm.erreur != nil },
            set: { if !$0 { vm.erreur = nil } }
        )) {
            Button("OK") { vm.erreur = nil }
        } message: {
            Text(vm.erreur ?? "")
        }
    }
}

// ── Titre du document ─────────────────────────────────────────────────────────

private struct TitreDocView: View {
    @Binding var titre: String
    let onSauvegarder: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Sans titre", text: $titre, axis: .vertical)
            .font(.system(size: 32, weight: .bold))
            .focused($focused)
            .submitLabel(.done)
            .onSubmit { onSauvegarder(); focused = false }
            .onChange(of: focused) { _, estFocus in if !estFocus { onSauvegarder() } }
    }
}

// ── Ligne de bloc ─────────────────────────────────────────────────────────────

struct BlocRowView: View {
    @Binding var bloc: EditableBlock
    @Binding var autoFocusId: String?
    let onSauvegarder: () -> Void
    let onSupprimer: () -> Void
    let onNouveauBloc: (String) -> Void

    var body: some View {
        Group {
            switch bloc.content {
            case .text:
                TexteRowView(bloc: $bloc, autoFocusId: $autoFocusId,
                             onSauvegarder: onSauvegarder, onNouveauBloc: onNouveauBloc)
            case .heading(let level, _):
                HeadingRowView(bloc: $bloc, level: level, autoFocusId: $autoFocusId,
                               onSauvegarder: onSauvegarder, onNouveauBloc: onNouveauBloc)
            case .quote:
                CitationRowView(bloc: $bloc, autoFocusId: $autoFocusId,
                                onSauvegarder: onSauvegarder, onNouveauBloc: onNouveauBloc)
            case .todo:
                TodoRowView(bloc: $bloc, autoFocusId: $autoFocusId,
                            onSauvegarder: onSauvegarder, onNouveauBloc: onNouveauBloc)
            case .divider:
                Divider().padding(.vertical, 12)
            default:
                EmptyView()
            }
        }
        .contextMenu {
            Button(role: .destructive, action: onSupprimer) {
                Label("Supprimer le bloc", systemImage: "trash")
            }
        }
    }
}

// ── Helpers partagés ──────────────────────────────────────────────────────────

private func detecterRetourChariot(_ texte: String,
                                   bloc: inout EditableBlock,
                                   onSauvegarder: () -> Void,
                                   onNouveauBloc: (String) -> Void) -> Bool {
    guard let idx = texte.firstIndex(of: "\n") else { return false }
    let avant = String(texte[..<idx])
    let apres = String(texte[texte.index(after: idx)...])
    bloc.texte = avant
    onSauvegarder()
    onNouveauBloc(apres)
    return true
}

private func focuserSiBesoin(blocId: String,
                              autoFocusId: inout String?,
                              setFocus: @escaping () -> Void) {
    guard autoFocusId == blocId else { return }
    autoFocusId = nil
    DispatchQueue.main.async { setFocus() }
}

// ── Texte ─────────────────────────────────────────────────────────────────────

private struct TexteRowView: View {
    @Binding var bloc: EditableBlock
    @Binding var autoFocusId: String?
    let onSauvegarder: () -> Void
    let onNouveauBloc: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Texte…", text: $bloc.texte, axis: .vertical)
            .font(.body)
            .focused($focused)
            .padding(.vertical, 5)
            .onChange(of: focused)    { _, estFocus in if !estFocus { onSauvegarder() } }
            .onChange(of: bloc.texte) { _, v in traiter(v) }
            .onAppear { focuserSiBesoin(blocId: bloc.id, autoFocusId: &autoFocusId) { focused = true } }
    }

    private func traiter(_ texte: String) {
        var b = bloc
        if detecterRetourChariot(texte, bloc: &b, onSauvegarder: onSauvegarder, onNouveauBloc: onNouveauBloc) {
            bloc = b; return
        }
        // Raccourcis markdown
        switch texte {
        case "# ":   convertir(.heading(level: 1, text: []))
        case "## ":  convertir(.heading(level: 2, text: []))
        case "### ": convertir(.heading(level: 3, text: []))
        case "> ":   convertir(.quote(icon: "", text: []))
        case "[ ] ", "[] ": convertir(.todo(done: false, text: []))
        case "---":  convertir(.divider)
        default: break
        }
    }

    private func convertir(_ contenu: BlockContentFfi) {
        bloc.texte = ""
        bloc.content = contenu
        onSauvegarder()
    }
}

// ── Heading ───────────────────────────────────────────────────────────────────

private struct HeadingRowView: View {
    @Binding var bloc: EditableBlock
    let level: Int
    @Binding var autoFocusId: String?
    let onSauvegarder: () -> Void
    let onNouveauBloc: (String) -> Void
    @FocusState private var focused: Bool

    private var font: Font {
        switch level {
        case 1:  return .system(size: 26, weight: .bold)
        case 2:  return .system(size: 22, weight: .semibold)
        default: return .system(size: 18, weight: .semibold)
        }
    }

    var body: some View {
        TextField("Titre…", text: $bloc.texte, axis: .vertical)
            .font(font)
            .focused($focused)
            .padding(.top, level == 1 ? 16 : 10)
            .padding(.bottom, 4)
            .onChange(of: focused)    { _, estFocus in if !estFocus { onSauvegarder() } }
            .onChange(of: bloc.texte) { _, v in
                var b = bloc
                if detecterRetourChariot(v, bloc: &b, onSauvegarder: onSauvegarder, onNouveauBloc: onNouveauBloc) {
                    bloc = b
                }
            }
            .onAppear { focuserSiBesoin(blocId: bloc.id, autoFocusId: &autoFocusId) { focused = true } }
    }
}

// ── Citation ──────────────────────────────────────────────────────────────────

private struct CitationRowView: View {
    @Binding var bloc: EditableBlock
    @Binding var autoFocusId: String?
    let onSauvegarder: () -> Void
    let onNouveauBloc: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3)
                .padding(.vertical, 2)
            TextField("Citation…", text: $bloc.texte, axis: .vertical)
                .font(.body.italic())
                .foregroundStyle(.secondary)
                .focused($focused)
                .padding(.leading, 14)
                .padding(.vertical, 5)
                .onChange(of: focused)    { _, estFocus in if !estFocus { onSauvegarder() } }
                .onChange(of: bloc.texte) { _, v in
                    var b = bloc
                    if detecterRetourChariot(v, bloc: &b, onSauvegarder: onSauvegarder, onNouveauBloc: onNouveauBloc) {
                        bloc = b
                    }
                }
                .onAppear { focuserSiBesoin(blocId: bloc.id, autoFocusId: &autoFocusId) { focused = true } }
        }
        .padding(.vertical, 4)
    }
}

// ── Todo ──────────────────────────────────────────────────────────────────────

private struct TodoRowView: View {
    @Binding var bloc: EditableBlock
    @Binding var autoFocusId: String?
    let onSauvegarder: () -> Void
    let onNouveauBloc: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                bloc.done.toggle()
                onSauvegarder()
            } label: {
                Image(systemName: bloc.done ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(bloc.done ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            TextField("À faire…", text: $bloc.texte, axis: .vertical)
                .font(.body)
                .foregroundStyle(bloc.done ? .secondary : .primary)
                .focused($focused)
                .padding(.vertical, 5)
                .onChange(of: focused)    { _, estFocus in if !estFocus { onSauvegarder() } }
                .onChange(of: bloc.texte) { _, v in
                    var b = bloc
                    if detecterRetourChariot(v, bloc: &b, onSauvegarder: onSauvegarder, onNouveauBloc: onNouveauBloc) {
                        bloc = b
                    }
                }
                .onAppear { focuserSiBesoin(blocId: bloc.id, autoFocusId: &autoFocusId) { focused = true } }
        }
        .padding(.vertical, 2)
    }
}

// ── Bouton ajouter ────────────────────────────────────────────────────────────

private struct BoutonAjouterBloc: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                Text("Nouveau bloc")
            }
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

// ── Sélecteur de type ─────────────────────────────────────────────────────────

private struct BlocPickerSheet: View {
    let onSelect: (TypeBlocNouvel) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(TypeBlocNouvel.allCases) { type in
                Button {
                    onSelect(type)
                    dismiss()
                } label: {
                    Label(type.rawValue, systemImage: type.icone)
                        .foregroundStyle(.primary)
                }
            }
            .navigationTitle("Ajouter un bloc")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
