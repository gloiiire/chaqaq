import SwiftUI

// ── Auto-focus (extension partagée) ──────────────────────────────────────────

private extension View {
    func autoFocuserSiBesoin(blocId: String,
                              autoFocusId: Binding<String?>,
                              autoFocusOffset: Binding<Int?>,
                              cursorAt: Binding<Int?>,
                              focused: Binding<Bool>) -> some View {
        self
            .onAppear {
                guard autoFocusId.wrappedValue == blocId else { return }
                autoFocusId.wrappedValue = nil
                let off = autoFocusOffset.wrappedValue
                autoFocusOffset.wrappedValue = nil
                DispatchQueue.main.async { cursorAt.wrappedValue = off; focused.wrappedValue = true }
            }
            .onChange(of: autoFocusId.wrappedValue) { _, newId in
                guard newId == blocId else { return }
                autoFocusId.wrappedValue = nil
                let off = autoFocusOffset.wrappedValue
                autoFocusOffset.wrappedValue = nil
                DispatchQueue.main.async { cursorAt.wrappedValue = off; focused.wrappedValue = true }
            }
    }
}

// ── Modèle éditable ───────────────────────────────────────────────────────────

struct EditableBlock: Identifiable {
    let id: String
    var content: BlockContentFfi
    var spans: [InlineTextFfi]
    var done: Bool
    var texteSimple: String { spans.map(\.content).joined() }
}

// ── View Model ────────────────────────────────────────────────────────────────

@MainActor
final class DocumentViewModel: ObservableObject {
    let docId: String
    @Published var titre: String = ""
    @Published var blocs: [EditableBlock] = []
    @Published var erreur: String?
    @Published var autoFocusId: String?
    @Published var autoFocusOffset: Int? = nil
    private var idBlocFocuse: String? = nil
    private var navTimer: Timer?
    var navEnRepetition: Bool { navTimer != nil }

    private let api: ChaqaqApi

    init(docId: String, api: ChaqaqApi) {
        self.docId = docId
        self.api   = api
    }

    func charger() {
        do {
            let json = try api.obtenirDocumentJson(id: docId)
            guard let data = json.data(using: .utf8) else { return }
            let doc = try JSONDecoder().decode(DocumentFfi.self, from: data)
            titre = doc.title.map(\.content).joined()
            blocs = doc.blocks.map {
                EditableBlock(id: $0.id, content: $0.content,
                              spans: $0.content.spansOuVide,
                              done:  $0.content.doneTodo)
            }
        } catch { erreur = error.localizedDescription }
    }

    func sauvegarderTitre() {
        try? api.modifierTitreDocument(id: docId, nouveauTitre: titre)
    }

    func sauvegarderBloc(_ bloc: EditableBlock) {
        do {
            let nouveau = bloc.content.avecSpans(bloc.spans, done: bloc.done)
            let data    = try JSONEncoder().encode(nouveau)
            try api.modifierBloc(docId: docId, blocId: bloc.id,
                                 contenuJson: String(data: data, encoding: .utf8)!)
        } catch { erreur = error.localizedDescription }
    }

    func sauvegarderBloc(id: String, spans: [InlineTextFfi]) {
        guard let idx = blocs.firstIndex(where: { $0.id == id }) else { return }
        blocs[idx].spans = spans
        sauvegarderBloc(blocs[idx])
    }

    func ajouterBloc(type: TypeBlocNouvel, texteInitial: String = "", apresId: String? = nil) {
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
            let data  = try JSONEncoder().encode(contenu)
            let newId = try api.ajouterBloc(docId: docId,
                                            blocContentJson: String(data: data, encoding: .utf8)!)
            let spansInit: [InlineTextFfi] = texteInitial.isEmpty
                ? [] : [InlineTextFfi(content: texteInitial, styles: [])]
            let newBloc = EditableBlock(id: newId, content: contenu, spans: spansInit, done: false)

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
        do {
            try api.supprimerBloc(docId: docId, blocId: id)
            blocs.removeAll { $0.id == id }
        } catch { erreur = error.localizedDescription }
    }

    func demarrerNavRepetition(depuis: String, suivant: Bool) {
        guard !navEnRepetition else { return }
        idBlocFocuse = depuis
        navTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.pasNavigation(suivant: suivant)
        }
    }

    func stopNavRepetition() {
        navTimer?.invalidate()
        navTimer = nil
        idBlocFocuse = nil
    }

    private func pasNavigation(suivant: Bool) {
        guard let cid = idBlocFocuse,
              let idx = blocs.firstIndex(where: { $0.id == cid }) else { stopNavRepetition(); return }
        if suivant {
            guard idx < blocs.count - 1 else { stopNavRepetition(); return }
            let nid = blocs[idx + 1].id
            autoFocusOffset = 0; idBlocFocuse = nid; autoFocusId = nid
        } else {
            guard idx > 0 else { stopNavRepetition(); return }
            let nid = blocs[idx - 1].id
            autoFocusOffset = nil; idBlocFocuse = nid; autoFocusId = nid
        }
    }

    func deplacerBloc(from: IndexSet, to: Int) {
        blocs.move(fromOffsets: from, toOffset: to)
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
    @State private var focusTitre = false

    init(docId: String, api: ChaqaqApi) {
        _vm = StateObject(wrappedValue: DocumentViewModel(docId: docId, api: api))
    }

    var body: some View {
        List {
            TitreDocView(titre: $vm.titre, focusDemande: $focusTitre,
                         onSauvegarder: vm.sauvegarderTitre,
                         onNouveauBloc: { vm.ajouterBloc(type: .texte) })
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
                .moveDisabled(true)
                .deleteDisabled(true)

            if vm.blocs.isEmpty {
                EtatVideSaisie { vm.ajouterBloc(type: .texte) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .moveDisabled(true)
                    .deleteDisabled(true)
            }

            ForEach($vm.blocs) { $bloc in
                BlocRowView(
                    bloc: $bloc,
                    autoFocusId: $vm.autoFocusId,
                    autoFocusOffset: $vm.autoFocusOffset,
                    onSauvegarder: {
                        guard let idx = vm.blocs.firstIndex(where: { $0.id == bloc.id }) else { return }
                        vm.sauvegarderBloc(vm.blocs[idx])
                    },
                    onSauvegarderSpans: { spans in
                        vm.sauvegarderBloc(id: bloc.id, spans: spans)
                    },
                    onSupprimer: {
                        if let idx = vm.blocs.firstIndex(where: { $0.id == bloc.id }) {
                            if idx > 0 {
                                let prevId = vm.blocs[idx - 1].id
                                vm.supprimerBloc(id: bloc.id)
                                vm.autoFocusId = prevId
                            } else {
                                vm.supprimerBloc(id: bloc.id)
                                focusTitre = true
                            }
                        }
                    },
                    onNouveauBloc: { apres in
                        vm.ajouterBloc(type: .texte, texteInitial: apres, apresId: bloc.id)
                    },
                    onFusionner: vm.blocs.first?.id == bloc.id ? nil : { spansAMerger in
                        guard let idx = vm.blocs.firstIndex(where: { $0.id == bloc.id }), idx > 0 else { return }
                        let prevIdx      = idx - 1
                        let prevId       = vm.blocs[prevIdx].id
                        let offsetFusion = vm.blocs[prevIdx].spans.map(\.content).joined().count
                        vm.blocs[prevIdx].spans += spansAMerger
                        vm.sauvegarderBloc(vm.blocs[prevIdx])
                        vm.supprimerBloc(id: bloc.id)
                        vm.autoFocusOffset = offsetFusion
                        vm.autoFocusId     = prevId
                    },
                    onNaviguerPrecedent: {
                        guard !vm.navEnRepetition else { return }
                        guard let idx = vm.blocs.firstIndex(where: { $0.id == bloc.id }) else { return }
                        if idx > 0 {
                            let nid = vm.blocs[idx - 1].id
                            vm.autoFocusOffset = nil
                            vm.autoFocusId = nid
                            vm.demarrerNavRepetition(depuis: nid, suivant: false)
                        } else {
                            focusTitre = true
                        }
                    },
                    onNaviguerSuivant: {
                        guard !vm.navEnRepetition else { return }
                        guard let idx = vm.blocs.firstIndex(where: { $0.id == bloc.id }),
                              idx < vm.blocs.count - 1 else { return }
                        let nid = vm.blocs[idx + 1].id
                        vm.autoFocusOffset = 0
                        vm.autoFocusId = nid
                        vm.demarrerNavRepetition(depuis: nid, suivant: true)
                    },
                    onNavRepeterArreter: { vm.stopNavRepetition() }
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
        .scrollDismissesKeyboard(.interactively)
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
    @Binding var focusDemande: Bool
    let onSauvegarder: () -> Void
    let onNouveauBloc: () -> Void
    @State private var focused = false

    var body: some View {
        TitreSaisie(texte: $titre, isFocused: $focused,
                    onSauvegarder: onSauvegarder, onNouveauBloc: onNouveauBloc)
            .onChange(of: focusDemande) { _, demande in
                if demande {
                    focusDemande = false
                    DispatchQueue.main.async { focused = true }
                }
            }
    }
}

private struct TitreSaisie: UIViewRepresentable {
    @Binding var texte: String
    @Binding var isFocused: Bool
    let onSauvegarder: () -> Void
    let onNouveauBloc: () -> Void

    private let police = UIFont.systemFont(ofSize: 32, weight: .bold)

    func makeUIView(context: Context) -> ExpandingTextView {
        let tv = ExpandingTextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.font = police
        tv.isScrollEnabled = false
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        context.coordinator.tv = tv
        tv.attributedText = texte.isEmpty
            ? context.coordinator.placeholderAttr()
            : NSAttributedString(string: texte, attributes: [.font: police, .foregroundColor: UIColor.label])
        return tv
    }

    func updateUIView(_ tv: ExpandingTextView, context: Context) {
        context.coordinator.parent = self
        if !context.coordinator.enEdition {
            tv.attributedText = texte.isEmpty
                ? context.coordinator.placeholderAttr()
                : NSAttributedString(string: texte, attributes: [.font: police, .foregroundColor: UIColor.label])
        }
        if isFocused && !tv.isFirstResponder {
            DispatchQueue.main.async {
                _ = tv.becomeFirstResponder()
                tv.selectedRange = NSRange(location: tv.text.count, length: 0)
            }
        } else if !isFocused && tv.isFirstResponder {
            tv.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TitreSaisie
        weak var tv: ExpandingTextView?
        var enEdition = false

        init(parent: TitreSaisie) { self.parent = parent }

        func placeholderAttr() -> NSAttributedString {
            NSAttributedString(string: "Sans titre",
                               attributes: [.font: parent.police, .foregroundColor: UIColor.tertiaryLabel])
        }

        func textViewDidBeginEditing(_ tv: UITextView) {
            enEdition = true
            parent.isFocused = true
            if tv.textColor == .tertiaryLabel {
                tv.attributedText = NSAttributedString(string: "",
                    attributes: [.font: parent.police, .foregroundColor: UIColor.label])
            }
            tv.typingAttributes = [.font: parent.police, .foregroundColor: UIColor.label]
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            enEdition = false
            parent.isFocused = false
            parent.texte = tv.text ?? ""
            parent.onSauvegarder()
            if parent.texte.isEmpty { tv.attributedText = placeholderAttr() }
        }

        func textViewDidChange(_ tv: UITextView) {
            guard let texte = tv.text else { return }
            if let idx = texte.firstIndex(of: "\n") {
                tv.text = String(texte[texte.startIndex..<idx])
                parent.texte = tv.text
                parent.onSauvegarder()
                parent.onNouveauBloc()
                return
            }
            parent.texte = texte
        }
    }
}

// ── État vide cliquable ───────────────────────────────────────────────────────

private struct EtatVideSaisie: View {
    let onCommencer: () -> Void
    @State private var focused = false

    var body: some View {
        RichTextEditor(
            spans: .constant([]),
            isFocused: $focused,
            placeholder: "Commence à écrire…",
            onSave: nil,
            onNewBlock: nil,
            onSupprimerBloc: nil,
            onConvert: nil
        )
        .onChange(of: focused) { _, estFocus in
            if estFocus { onCommencer() }
        }
    }
}

// ── Ligne de bloc ─────────────────────────────────────────────────────────────

private struct BlocRowView: View {
    @Binding var bloc: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let onSauvegarder: () -> Void
    let onSauvegarderSpans: ([InlineTextFfi]) -> Void
    let onSupprimer: () -> Void
    let onNouveauBloc: (String) -> Void
    var onFusionner: (([InlineTextFfi]) -> Void)?
    var onNaviguerPrecedent: (() -> Void)?
    var onNaviguerSuivant: (() -> Void)?
    var onNavRepeterArreter: (() -> Void)?

    var body: some View {
        Group {
            switch bloc.content {
            case .text:
                TexteRowView(bloc: $bloc, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                             onSauvegarder: onSauvegarder,
                             onSauvegarderSpans: onSauvegarderSpans,
                             onSupprimer: onSupprimer,
                             onNouveauBloc: onNouveauBloc, onFusionner: onFusionner,
                             onNaviguerPrecedent: onNaviguerPrecedent, onNaviguerSuivant: onNaviguerSuivant,
                             onNavRepeterArreter: onNavRepeterArreter)
            case .heading(let level, _):
                HeadingRowView(bloc: $bloc, level: level, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                               onSauvegarder: onSauvegarder,
                               onSauvegarderSpans: onSauvegarderSpans,
                               onSupprimer: onSupprimer,
                               onNouveauBloc: onNouveauBloc, onFusionner: onFusionner,
                               onNaviguerPrecedent: onNaviguerPrecedent, onNaviguerSuivant: onNaviguerSuivant,
                               onNavRepeterArreter: onNavRepeterArreter)
            case .quote:
                CitationRowView(bloc: $bloc, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                                onSauvegarder: onSauvegarder,
                                onSauvegarderSpans: onSauvegarderSpans,
                                onSupprimer: onSupprimer,
                                onNouveauBloc: onNouveauBloc, onFusionner: onFusionner,
                                onNaviguerPrecedent: onNaviguerPrecedent, onNaviguerSuivant: onNaviguerSuivant,
                                onNavRepeterArreter: onNavRepeterArreter)
            case .todo:
                TodoRowView(bloc: $bloc, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                            onSauvegarder: onSauvegarder,
                            onSauvegarderSpans: onSauvegarderSpans,
                            onSupprimer: onSupprimer,
                            onNouveauBloc: onNouveauBloc, onFusionner: onFusionner,
                            onNaviguerPrecedent: onNaviguerPrecedent, onNaviguerSuivant: onNaviguerSuivant,
                            onNavRepeterArreter: onNavRepeterArreter)
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

// ── Texte ─────────────────────────────────────────────────────────────────────

private struct TexteRowView: View {
    @Binding var bloc: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let onSauvegarder: () -> Void
    let onSauvegarderSpans: ([InlineTextFfi]) -> Void
    let onSupprimer: () -> Void
    let onNouveauBloc: (String) -> Void
    var onFusionner: (([InlineTextFfi]) -> Void)?
    var onNaviguerPrecedent: (() -> Void)?
    var onNaviguerSuivant: (() -> Void)?
    var onNavRepeterArreter: (() -> Void)?
    @State private var focused = false
    @State private var cursorAt: Int?

    var body: some View {
        RichTextEditor(
            spans: $bloc.spans,
            isFocused: $focused,
            placeholder: "Texte…",
            baseFont: .preferredFont(forTextStyle: .body),
            focusCursorAt: cursorAt,
            onSave: onSauvegarder,
            onSaveSpans: onSauvegarderSpans,
            onNewBlock: onNouveauBloc,
            onSupprimerBloc: onSupprimer,
            onFusionnerAvecPrecedent: onFusionner,
            onConvert: { contenu in bloc.content = contenu; bloc.spans = []; onSauvegarder() },
            onNaviguerPrecedent: onNaviguerPrecedent,
            onNaviguerSuivant: onNaviguerSuivant,
            onNavRepeterArreter: onNavRepeterArreter)
        .autoFocuserSiBesoin(blocId: bloc.id, autoFocusId: $autoFocusId,
                              autoFocusOffset: $autoFocusOffset, cursorAt: $cursorAt, focused: $focused)
    }
}

// ── Heading ───────────────────────────────────────────────────────────────────

private struct HeadingRowView: View {
    @Binding var bloc: EditableBlock
    let level: Int
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let onSauvegarder: () -> Void
    let onSauvegarderSpans: ([InlineTextFfi]) -> Void
    let onSupprimer: () -> Void
    let onNouveauBloc: (String) -> Void
    var onFusionner: (([InlineTextFfi]) -> Void)?
    var onNaviguerPrecedent: (() -> Void)?
    var onNaviguerSuivant: (() -> Void)?
    var onNavRepeterArreter: (() -> Void)?
    @State private var focused = false
    @State private var cursorAt: Int?

    private var uiFont: UIFont {
        switch level {
        case 1:  return .systemFont(ofSize: 26, weight: .bold)
        case 2:  return .systemFont(ofSize: 22, weight: .semibold)
        default: return .systemFont(ofSize: 18, weight: .semibold)
        }
    }

    var body: some View {
        RichTextEditor(
            spans: $bloc.spans,
            isFocused: $focused,
            placeholder: "Titre…",
            baseFont: uiFont,
            focusCursorAt: cursorAt,
            onSave: onSauvegarder,
            onSaveSpans: onSauvegarderSpans,
            onNewBlock: onNouveauBloc,
            onSupprimerBloc: onSupprimer,
            onFusionnerAvecPrecedent: onFusionner,
            onConvert: { contenu in bloc.content = contenu; bloc.spans = []; onSauvegarder() },
            onNaviguerPrecedent: onNaviguerPrecedent,
            onNaviguerSuivant: onNaviguerSuivant,
            onNavRepeterArreter: onNavRepeterArreter)
        .padding(.top, level == 1 ? 16 : 10)
        .padding(.bottom, 4)
        .autoFocuserSiBesoin(blocId: bloc.id, autoFocusId: $autoFocusId,
                              autoFocusOffset: $autoFocusOffset, cursorAt: $cursorAt, focused: $focused)
    }
}

// ── Citation ──────────────────────────────────────────────────────────────────

private struct CitationRowView: View {
    @Binding var bloc: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let onSauvegarder: () -> Void
    let onSauvegarderSpans: ([InlineTextFfi]) -> Void
    let onSupprimer: () -> Void
    let onNouveauBloc: (String) -> Void
    var onFusionner: (([InlineTextFfi]) -> Void)?
    var onNaviguerPrecedent: (() -> Void)?
    var onNaviguerSuivant: (() -> Void)?
    var onNavRepeterArreter: (() -> Void)?
    @State private var focused = false
    @State private var cursorAt: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3)
                .padding(.vertical, 6)
            RichTextEditor(
                spans: $bloc.spans,
                isFocused: $focused,
                placeholder: "Citation…",
                baseFont: .italicSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize),
                focusCursorAt: cursorAt,
                onSave: onSauvegarder,
                onSaveSpans: onSauvegarderSpans,
                onNewBlock: onNouveauBloc,
                onSupprimerBloc: onSupprimer,
                onFusionnerAvecPrecedent: onFusionner,
                onConvert: { contenu in bloc.content = contenu; bloc.spans = []; onSauvegarder() },
                onNaviguerPrecedent: onNaviguerPrecedent,
                onNaviguerSuivant: onNaviguerSuivant,
                onNavRepeterArreter: onNavRepeterArreter)
            .padding(.leading, 14)
        }
        .padding(.vertical, 4)
        .autoFocuserSiBesoin(blocId: bloc.id, autoFocusId: $autoFocusId,
                              autoFocusOffset: $autoFocusOffset, cursorAt: $cursorAt, focused: $focused)
    }
}

// ── Todo ──────────────────────────────────────────────────────────────────────

private struct TodoRowView: View {
    @Binding var bloc: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let onSauvegarder: () -> Void
    let onSauvegarderSpans: ([InlineTextFfi]) -> Void
    let onSupprimer: () -> Void
    let onNouveauBloc: (String) -> Void
    var onFusionner: (([InlineTextFfi]) -> Void)?
    var onNaviguerPrecedent: (() -> Void)?
    var onNaviguerSuivant: (() -> Void)?
    var onNavRepeterArreter: (() -> Void)?
    @State private var focused = false
    @State private var cursorAt: Int?

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
            .padding(.top, 8)

            RichTextEditor(
                spans: $bloc.spans,
                isFocused: $focused,
                placeholder: "À faire…",
                baseFont: .preferredFont(forTextStyle: .body),
                extraAttrs: bloc.done ? [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: UIColor.secondaryLabel
                ] : nil,
                focusCursorAt: cursorAt,
                onSave: onSauvegarder,
                onSaveSpans: onSauvegarderSpans,
                onNewBlock: onNouveauBloc,
                onSupprimerBloc: onSupprimer,
                onFusionnerAvecPrecedent: onFusionner,
                onConvert: nil,
                onNaviguerPrecedent: onNaviguerPrecedent,
                onNaviguerSuivant: onNaviguerSuivant,
                onNavRepeterArreter: onNavRepeterArreter)
        }
        .padding(.vertical, 2)
        .autoFocuserSiBesoin(blocId: bloc.id, autoFocusId: $autoFocusId,
                              autoFocusOffset: $autoFocusOffset, cursorAt: $cursorAt, focused: $focused)
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
