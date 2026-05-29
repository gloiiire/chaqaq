import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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
    @Published var couverture: String?
    @Published var blocs: [EditableBlock] = []
    @Published var erreur: String?
    @Published var autoFocusId: String?
    @Published var autoFocusOffset: Int? = nil
    var idBlocActif: String? = nil
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
            couverture = doc.cover
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

    func sauvegarderCouverture(_ nouvelleCouverture: String?) {
        do {
            couverture = nouvelleCouverture
            try api.modifierCouvertureDocument(id: docId, couverture: nouvelleCouverture)
        } catch { erreur = error.localizedDescription }
    }

    func sauvegarderImageCouverture(data: Data, extensionFichier: String = "jpg") {
        do {
            let nom = try Self.ecrireImageCouverture(data: data, docId: docId, extensionFichier: extensionFichier)
            sauvegarderCouverture(nom)
        } catch { erreur = error.localizedDescription }
    }

    func sauvegarderImageCouvertureDepuisFichier(_ url: URL) {
        let acces = url.startAccessingSecurityScopedResource()
        defer {
            if acces { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            let ext = Self.extensionImage(url.pathExtension)
            let nom = try Self.ecrireImageCouverture(data: data, docId: docId, extensionFichier: ext)
            sauvegarderCouverture(nom)
        } catch { erreur = error.localizedDescription }
    }

    private static func ecrireImageCouverture(data: Data, docId: String, extensionFichier: String) throws -> String {
        let dossier = try dossierCouvertures()
        let nom = docId.replacingOccurrences(of: "/", with: "-") + "." + extensionFichier
        let url = dossier.appendingPathComponent(nom)
        try data.write(to: url, options: .atomic)
        return nom
    }

    fileprivate static func dossierCouvertures() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dossier = base.appendingPathComponent("Chaqaq/Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        return dossier
    }

    private static func extensionImage(_ ext: String) -> String {
        let nettoyee = ext.lowercased()
        return ["jpg", "jpeg", "png", "heic", "webp"].contains(nettoyee) ? nettoyee : "jpg"
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
            case .callout:    contenu = .quote(icon: "💡", text: [])
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

    func supprimerBlocs(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        do {
            for id in ids {
                try api.supprimerBloc(docId: docId, blocId: id)
            }
            blocs.removeAll { ids.contains($0.id) }
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
    case citation = "Citation", callout = "Callout", todo = "À faire", separateur = "Séparateur"
    var id: String { rawValue }
    var icone: String {
        switch self {
        case .texte:      return "text.alignleft"
        case .titre1:     return "1.circle.fill"
        case .titre2:     return "2.circle"
        case .titre3:     return "3.circle"
        case .citation:   return "quote.bubble"
        case .callout:    return "lightbulb"
        case .todo:       return "checkmark.square"
        case .separateur: return "minus"
        }
    }
}

// ── Helpers emoji persistance ─────────────────────────────────────────────────

private let kEmojisRecentsKey = "document.icon.recentEmojis"

private func chargerEmojisRecents() -> [String] {
    UserDefaults.standard.stringArray(forKey: kEmojisRecentsKey) ?? []
}

@discardableResult
private func enregistrerEmojiRecent(_ emoji: String) -> [String] {
    let existants = UserDefaults.standard.stringArray(forKey: kEmojisRecentsKey) ?? []
    let liste = Array(([emoji] + existants.filter { $0 != emoji }).prefix(6))
    UserDefaults.standard.set(liste, forKey: kEmojisRecentsKey)
    return liste
}

// ── Vue document ──────────────────────────────────────────────────────────────

struct DocumentView: View {
    @StateObject private var vm: DocumentViewModel
    @State private var showingBlocPicker = false
    @State private var editMode: EditMode = .inactive
    @State private var focusTitre = false
    @State private var titreDansNavBar = false
    @State private var documentVerrouille: Bool
    @State private var documentIcone: String?
    @State private var emojisRecents: [String]
    @State private var blocsSelectionnes: Set<String> = []
    @State private var clavierVisible = false
    private let verrouillageKey: String
    private let iconeKey: String

    var onDisparaitre: (() -> Void)? = nil

    init(docId: String, api: ChaqaqApi, onDisparaitre: (() -> Void)? = nil) {
        let lockKey = Self.cleVerrouillage(docId: docId)
        let iconKey = Self.cleIcone(docId: docId)
        _vm = StateObject(wrappedValue: DocumentViewModel(docId: docId, api: api))
        _documentVerrouille = State(initialValue: UserDefaults.standard.bool(forKey: lockKey))
        _documentIcone = State(initialValue: UserDefaults.standard.string(forKey: iconKey))
        _emojisRecents = State(initialValue: chargerEmojisRecents())
        verrouillageKey = lockKey
        iconeKey = iconKey
        self.onDisparaitre = onDisparaitre
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
        List {
            DocumentDecorView(
                couverture: vm.couverture,
                icone: documentIcone,
                emojisRecents: emojisRecents,
                verrouille: documentVerrouille,
                onCouverture: { vm.sauvegarderCouverture($0) },
                onImageData: { data in vm.sauvegarderImageCouverture(data: data) },
                onImageFichier: { url in vm.sauvegarderImageCouvertureDepuisFichier(url) },
                onIcone: { nouvelleIcone in
                    documentIcone = nouvelleIcone
                    if let nouvelleIcone {
                        UserDefaults.standard.set(nouvelleIcone, forKey: iconeKey)
                        emojisRecents = enregistrerEmojiRecent(nouvelleIcone)
                    } else {
                        UserDefaults.standard.removeObject(forKey: iconeKey)
                    }
                }
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .moveDisabled(true)
            .deleteDisabled(true)

            TitreDocView(titre: $vm.titre, focusDemande: $focusTitre,
                         onSauvegarder: vm.sauvegarderTitre,
                         onNouveauBloc: { vm.ajouterBloc(type: .texte) })
                .disabled(documentVerrouille)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
                .moveDisabled(true)
                .deleteDisabled(true)

            if vm.blocs.isEmpty && !documentVerrouille {
                EtatVideSaisie { vm.ajouterBloc(type: .texte) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .moveDisabled(true)
                    .deleteDisabled(true)
            }

            ForEach($vm.blocs) { $bloc in
                HStack(alignment: .center, spacing: 10) {
                    if editMode == .active {
                        boutonSelectionBloc(bloc.id)
                    }

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
                        onNavRepeterArreter: { vm.stopNavRepetition() },
                        onLongPressSelection: { selectionnerBlocDepuisPressionLongue(bloc.id) },
                        onFocus: { vm.idBlocActif = bloc.id }
                    )
                    .disabled(documentVerrouille || editMode == .active)
                    .allowsHitTesting(!documentVerrouille && editMode != .active)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if editMode == .active {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            basculerSelectionBloc(bloc.id)
                        }
                    }
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                        selectionnerBlocDepuisPressionLongue(bloc.id)
                    }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .swipeActions(edge: .trailing) {
                    if !documentVerrouille && editMode != .active {
                        Button(role: .destructive) { vm.supprimerBloc(id: bloc.id) } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            }
            .onMove(perform: vm.deplacerBloc)

            if !documentVerrouille {
                BoutonAjouterBloc { showingBlocPicker = true }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 40, trailing: 20))
                    .moveDisabled(true)
                    .deleteDisabled(true)
            }
        }
        .listStyle(.plain)
        .ignoresSafeArea(.container, edges: vm.couverture == nil ? [] : .top)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, offset in
            withAnimation(.easeInOut(duration: 0.15)) { titreDansNavBar = offset > 60 }
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.editMode, $editMode)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(vm.couverture == nil ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(vm.couverture == nil ? nil : .dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(vm.titre.isEmpty ? "Sans titre" : vm.titre)
                    .font(.headline)
                    .opacity(titreDansNavBar ? 1 : 0)
                    .offset(y: titreDansNavBar ? 0 : 8)
                    .animation(.easeOut(duration: 0.2), value: titreDansNavBar)
            }
            if editMode == .active && !blocsSelectionnes.isEmpty && !documentVerrouille {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        supprimerBlocsSelectionnes()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Supprimer les blocs sélectionnés")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let nouveauVerrouillage = !documentVerrouille
                    withAnimation(.easeInOut(duration: 0.15)) {
                        documentVerrouille = nouveauVerrouillage
                        if documentVerrouille {
                            editMode = .inactive
                            blocsSelectionnes.removeAll()
                            focusTitre = false
                            showingBlocPicker = false
                            vm.stopNavRepetition()
                        }
                    }
                    UserDefaults.standard.set(nouveauVerrouillage, forKey: verrouillageKey)
                } label: {
                    Image(systemName: documentVerrouille ? "lock.fill" : "lock.open.fill")
                }
                .accessibilityLabel(documentVerrouille ? "Déverrouiller le document" : "Verrouiller le document")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation {
                        editMode = editMode == .active ? .inactive : .active
                        if editMode != .active { blocsSelectionnes.removeAll() }
                    }
                } label: {
                    Image(systemName: editMode == .active ? "checkmark" : "arrow.up.arrow.down")
                }
                .disabled(documentVerrouille)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { clavierVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { clavierVisible = false }
        }
        .onAppear { vm.charger() }
        .onDisappear { vm.sauvegarderTitre(); onDisparaitre?() }
        .sheet(isPresented: $showingBlocPicker) {
            BlocPickerSheet { type in vm.ajouterBloc(type: type, apresId: vm.idBlocActif) }
        }
        .alert("Erreur", isPresented: Binding(
            get: { vm.erreur != nil },
            set: { if !$0 { vm.erreur = nil } }
        )) {
            Button("OK") { vm.erreur = nil }
        } message: {
            Text(vm.erreur ?? "")
        }

        if !documentVerrouille && editMode == .inactive && !clavierVisible {
            BoutonActionDoc { showingBlocPicker = true }
                .padding(.trailing, 24)
                .padding(.bottom, 32)
                .transition(.scale.combined(with: .opacity))
        }
        } // fin ZStack
    }

    private func boutonSelectionBloc(_ id: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                basculerSelectionBloc(id)
            }
        } label: {
            Image(systemName: blocsSelectionnes.contains(id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(blocsSelectionnes.contains(id) ? Color("SelectionTint") : .secondary)
                .frame(width: 28, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func basculerSelectionBloc(_ id: String) {
        if blocsSelectionnes.contains(id) {
            blocsSelectionnes.remove(id)
        } else {
            blocsSelectionnes.insert(id)
        }
    }

    private func selectionnerBlocDepuisPressionLongue(_ id: String) {
        guard !documentVerrouille else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            editMode = .active
            blocsSelectionnes.insert(id)
            focusTitre = false
            vm.stopNavRepetition()
        }
    }

    private func supprimerBlocsSelectionnes() {
        let ids = blocsSelectionnes
        withAnimation(.easeInOut(duration: 0.18)) {
            blocsSelectionnes.removeAll()
            vm.supprimerBlocs(ids: ids)
        }
    }

    private static func cleVerrouillage(docId: String) -> String {
        "document.locked.\(docId)"
    }

    private static func cleIcone(docId: String) -> String {
        "document.icon.\(docId)"
    }

}

// ── Cover + icône ─────────────────────────────────────────────────────────────

private struct DocumentDecorView: View {
    let couverture: String?
    let icone: String?
    let emojisRecents: [String]
    let verrouille: Bool
    let onCouverture: (String?) -> Void
    let onImageData: (Data) -> Void
    let onImageFichier: (URL) -> Void
    let onIcone: (String?) -> Void
    @State private var photoSelection: PhotosPickerItem?
    @State private var photosPickerOuvert = false
    @State private var fichierOuvert = false
    @State private var emojiPickerOuvert = false

    private let covers: [(String, String)] = [
        ("cover.nebula", "Nébuleuse"),
        ("cover.aurora", "Aurore"),
        ("cover.forest", "Forêt"),
        ("cover.sunset", "Crépuscule"),
        ("cover.ocean", "Océan")
    ]

    private let icones = ["🦁", "🌙", "🔥", "📜", "✨", "📚", "🧠", "🪐", "🌊", "🕊️", "💼", "🎯", "🧩"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let couverture {
                cover(couverture)
                    .containerRelativeFrame(.horizontal)
                    .frame(height: 220)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        iconeBouton
                            .padding(.leading, 24)
                            .offset(y: 42)
                    }
            } else if icone != nil {
                iconeBouton
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }

            if !verrouille {
                HStack(spacing: 10) {
                    coverMenu
                    iconMenu
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, couverture == nil && icone == nil ? 12 : 50)
            } else if couverture != nil {
                Color.clear.frame(height: 50)
            }
        }
        .containerRelativeFrame(.horizontal, alignment: .leading)
        .photosPicker(isPresented: $photosPickerOuvert, selection: $photoSelection, matching: .images)
        .fileImporter(isPresented: $fichierOuvert, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                onImageFichier(url)
            }
        }
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        onImageData(data)
                        photoSelection = nil
                    }
                }
            }
        }
        .sheet(isPresented: $emojiPickerOuvert) {
            EmojiPickerSheet(selection: icone, recents: emojisRecents) { emoji in
                onIcone(emoji)
            }
        }
    }

    private var iconeBouton: some View {
        Menu {
            iconMenuContenu
        } label: {
            Text(icone ?? "📝")
                .font(.system(size: 58))
                .frame(width: 76, height: 76)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(verrouille)
    }

    private var coverMenu: some View {
        Menu {
            coverMenuContenu
        } label: {
            Label(couverture == nil ? "Ajouter une couverture" : "Changer la couverture", systemImage: "photo")
        }
    }

    private var iconMenu: some View {
        Menu {
            iconMenuContenu
        } label: {
            Label(icone == nil ? "Ajouter une icône" : "Changer l’icône", systemImage: "face.smiling")
        }
    }

    @ViewBuilder
    private var coverMenuContenu: some View {
        Button {
            photosPickerOuvert = true
        } label: {
            Label("Choisir dans Photos", systemImage: "photo.on.rectangle")
        }
        Button {
            fichierOuvert = true
        } label: {
            Label("Choisir un fichier", systemImage: "folder")
        }
        Divider()
        ForEach(covers, id: \.0) { id, nom in
            Button(nom) { onCouverture(id) }
        }
        if couverture != nil {
            Divider()
            Button(role: .destructive) { onCouverture(nil) } label: {
                Label("Retirer la couverture", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var iconMenuContenu: some View {
        Button {
            emojiPickerOuvert = true
        } label: {
            Label("Tous les emojis", systemImage: "face.smiling")
        }
        Divider()
        ForEach(icones, id: \.self) { emoji in
            Button(emoji) { onIcone(emoji) }
        }
        if icone != nil {
            Divider()
            Button(role: .destructive) { onIcone(nil) } label: {
                Label("Retirer l’icône", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func cover(_ id: String) -> some View {
        if let image = imageCouverture(id) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipped()
        } else {
            switch id {
            case "cover.aurora":
                LinearGradient(colors: [.green, .cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            case "cover.forest":
                LinearGradient(colors: [Color(red: 0.05, green: 0.20, blue: 0.14), .green, Color(red: 0.70, green: 0.84, blue: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case "cover.sunset":
                LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            case "cover.ocean":
                LinearGradient(colors: [.blue, .cyan, Color(red: 0.05, green: 0.08, blue: 0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
            default:
                ZStack {
                    LinearGradient(colors: [Color(red: 0.02, green: 0.02, blue: 0.09), Color(red: 0.16, green: 0.25, blue: 0.55), Color(red: 0.95, green: 0.58, blue: 0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Canvas { context, size in
                        for i in 0..<48 {
                            let x = CGFloat((i * 53) % 997) / 997 * size.width
                            let y = CGFloat((i * 97) % 571) / 571 * size.height
                            let d = CGFloat((i % 3) + 1)
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)), with: .color(.white.opacity(i % 5 == 0 ? 0.95 : 0.55)))
                        }
                    }
                }
            }
        }
    }

    private func imageCouverture(_ id: String) -> UIImage? {
        if !id.hasPrefix("file://") && !id.hasPrefix("cover.") {
            guard let dossier = try? DocumentViewModel.dossierCouvertures() else { return nil }
            return UIImage(contentsOfFile: dossier.appendingPathComponent(id).path)
        }
        guard let url = URL(string: id), url.isFileURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

private struct EmojiPickerSheet: View {
    let selection: String?
    let recents: [String]
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saisie = ""
    @State private var saisieOuverte = false

    private let categories: [(String, [String])] = [
        ("Smileys", ["😀", "😃", "😄", "😁", "😆", "🥹", "😊", "🙂", "🙃", "😉", "😍", "😘", "😎", "🤓", "🥳", "😤", "😭", "😱", "🤯", "😴", "🤫", "🤭", "🫡", "🤔","👁️","👁️‍🗨️"]),
        ("Mains", ["👋", "👌", "🤌", "🤏", "✌️", "🤞", "🫰", "🤟", "🤘", "👍", "👎", "👏", "🙌", "🫶", "🙏", "✍️", "💪"]),
        ("Nature", ["🐶", "🐱", "🦁", "🐯", "🦊", "🐻", "🐼", "🐸", "🐵", "🦋", "🐝", "🌿", "🌲", "🌊", "🔥", "🌙", "☀️", "⭐️", "✨", "🌈", "🌧️", "❄️"]),
        ("Objets", ["📌", "📎", "✏️", "🖊️", "📜","📚", "📖", "💡", "🔒", "🔑", "🧭", "🎧", "📷", "💻", "📱", "⌚️", "🎮", "🧩", "🎯"]),
        ("Symboles", ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💎", "⚡️", "✅", "❌", "‼️", "⁉️", "🔔", "🔕", "♾️", "☮️"])
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if saisieOuverte {
                        saisiePersonnalisee
                    }

                    if !recents.isEmpty {
                        sectionEmoji(nom: "Récents", emojis: recents)
                    }

                    ForEach(categories, id: \.0) { nom, emojis in
                        sectionEmoji(nom: nom, emojis: emojis)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Icône")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            saisieOuverte.toggle()
                        }
                    } label: {
                        Image(systemName: "keyboard")
                    }
                    .accessibilityLabel("Saisir un emoji")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func validerSaisie() {
        guard let emoji = premierEmoji(saisie) else { return }
        onSelect(emoji)
        dismiss()
    }

    private var saisiePersonnalisee: some View {
        HStack(spacing: 10) {
            TextField("Emoji", text: $saisie)
                .font(.system(size: 28))
                .textFieldStyle(.plain)
                .frame(height: 48)
                .padding(.horizontal, 14)
                .background(Color.secondary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .submitLabel(.done)
                .onSubmit { validerSaisie() }

            Button {
                validerSaisie()
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
            }
            .disabled(premierEmoji(saisie) == nil)
        }
    }

    private func sectionEmoji(nom: String, emojis: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(nom)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 10) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        onSelect(emoji)
                        dismiss()
                    } label: {
                        Text(emoji)
                            .font(.system(size: 30))
                            .frame(width: 44, height: 44)
                            .background(selection == emoji ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func premierEmoji(_ texte: String) -> String? {
        texte.trimmingCharacters(in: .whitespacesAndNewlines)
            .first
            .map(String.init)
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
    @Environment(\.isEnabled) private var isEnabled
    let onSauvegarder: () -> Void
    let onNouveauBloc: () -> Void

    private let police = UIFont.systemFont(ofSize: 32, weight: .bold)

    func makeUIView(context: Context) -> ExpandingTextView {
        let tv = ExpandingTextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.font = police
        tv.tintColor = chaqaqSelectionTint
        tv.isEditable = isEnabled
        tv.isSelectable = isEnabled
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
        tv.tintColor = chaqaqSelectionTint
        tv.isEditable = isEnabled
        tv.isSelectable = isEnabled
        if !isEnabled && tv.isFirstResponder {
            tv.resignFirstResponder()
            DispatchQueue.main.async { isFocused = false }
        }
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
    var onLongPressSelection: (() -> Void)?
    var onFocus: (() -> Void)?

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
                             onNavRepeterArreter: onNavRepeterArreter,
                             onLongPressSelection: onLongPressSelection,
                             onFocus: onFocus)
            case .heading(let level, _):
                HeadingRowView(bloc: $bloc, level: level, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                               onSauvegarder: onSauvegarder,
                               onSauvegarderSpans: onSauvegarderSpans,
                               onSupprimer: onSupprimer,
                               onNouveauBloc: onNouveauBloc, onFusionner: onFusionner,
                               onNaviguerPrecedent: onNaviguerPrecedent, onNaviguerSuivant: onNaviguerSuivant,
                               onNavRepeterArreter: onNavRepeterArreter,
                               onLongPressSelection: onLongPressSelection,
                               onFocus: onFocus)
            case .quote(let icon, _):
                if icon.isEmpty {
                    CitationRowView(bloc: $bloc, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                                    onSauvegarder: onSauvegarder,
                                    onSauvegarderSpans: onSauvegarderSpans,
                                    onSupprimer: onSupprimer,
                                    onNouveauBloc: onNouveauBloc, onFusionner: onFusionner,
                                    onNaviguerPrecedent: onNaviguerPrecedent, onNaviguerSuivant: onNaviguerSuivant,
                                    onNavRepeterArreter: onNavRepeterArreter,
                                    onLongPressSelection: onLongPressSelection,
                                    onFocus: onFocus)
                } else {
                    CalloutRowView(bloc: $bloc, icon: icon, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                                   onSauvegarder: onSauvegarder,
                                   onSauvegarderSpans: onSauvegarderSpans,
                                   onSupprimer: onSupprimer,
                                   onNouveauBloc: onNouveauBloc, onFusionner: onFusionner,
                                   onNaviguerPrecedent: onNaviguerPrecedent, onNaviguerSuivant: onNaviguerSuivant,
                                   onNavRepeterArreter: onNavRepeterArreter,
                                   onLongPressSelection: onLongPressSelection,
                                   onFocus: onFocus)
                }
            case .todo:
                TodoRowView(bloc: $bloc, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                            onSauvegarder: onSauvegarder,
                            onSauvegarderSpans: onSauvegarderSpans,
                            onSupprimer: onSupprimer,
                            onNouveauBloc: onNouveauBloc, onFusionner: onFusionner,
                            onNaviguerPrecedent: onNaviguerPrecedent, onNaviguerSuivant: onNaviguerSuivant,
                            onNavRepeterArreter: onNavRepeterArreter,
                            onLongPressSelection: onLongPressSelection,
                            onFocus: onFocus)
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
    var onLongPressSelection: (() -> Void)?
    var onFocus: (() -> Void)?
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
            onLongPressSelection: onLongPressSelection,
            onNaviguerPrecedent: onNaviguerPrecedent,
            onNaviguerSuivant: onNaviguerSuivant,
            onNavRepeterArreter: onNavRepeterArreter)
        .autoFocuserSiBesoin(blocId: bloc.id, autoFocusId: $autoFocusId,
                              autoFocusOffset: $autoFocusOffset, cursorAt: $cursorAt, focused: $focused)
        .onChange(of: focused) { _, f in if f { onFocus?() } }
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
    var onLongPressSelection: (() -> Void)?
    var onFocus: (() -> Void)?
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
            onLongPressSelection: onLongPressSelection,
            onNaviguerPrecedent: onNaviguerPrecedent,
            onNaviguerSuivant: onNaviguerSuivant,
            onNavRepeterArreter: onNavRepeterArreter)
        .padding(.top, level == 1 ? 16 : 10)
        .padding(.bottom, 4)
        .autoFocuserSiBesoin(blocId: bloc.id, autoFocusId: $autoFocusId,
                              autoFocusOffset: $autoFocusOffset, cursorAt: $cursorAt, focused: $focused)
        .onChange(of: focused) { _, f in if f { onFocus?() } }
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
    var onLongPressSelection: (() -> Void)?
    var onFocus: (() -> Void)?
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
                onLongPressSelection: onLongPressSelection,
                onNaviguerPrecedent: onNaviguerPrecedent,
                onNaviguerSuivant: onNaviguerSuivant,
                onNavRepeterArreter: onNavRepeterArreter)
            .padding(.leading, 14)
        }
        .padding(.vertical, 4)
        .autoFocuserSiBesoin(blocId: bloc.id, autoFocusId: $autoFocusId,
                              autoFocusOffset: $autoFocusOffset, cursorAt: $cursorAt, focused: $focused)
        .onChange(of: focused) { _, f in if f { onFocus?() } }
    }
}

// ── Callout ───────────────────────────────────────────────────────────────────

private struct CalloutRowView: View {
    @Binding var bloc: EditableBlock
    let icon: String
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
    var onLongPressSelection: (() -> Void)?
    var onFocus: (() -> Void)?
    @State private var focused = false
    @State private var cursorAt: Int?
    @State private var emojiPickerOuvert = false
    @State private var emojisRecents = chargerEmojisRecents()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                emojiPickerOuvert = true
            } label: {
                Text(icon)
                    .font(.system(size: 28))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            RichTextEditor(
                spans: $bloc.spans,
                isFocused: $focused,
                placeholder: "Callout…",
                baseFont: .preferredFont(forTextStyle: .body),
                focusCursorAt: cursorAt,
                onSave: onSauvegarder,
                onSaveSpans: onSauvegarderSpans,
                onNewBlock: onNouveauBloc,
                onSupprimerBloc: onSupprimer,
                onFusionnerAvecPrecedent: onFusionner,
                onConvert: { contenu in bloc.content = contenu; bloc.spans = []; onSauvegarder() },
                onLongPressSelection: onLongPressSelection,
                onNaviguerPrecedent: onNaviguerPrecedent,
                onNaviguerSuivant: onNaviguerSuivant,
                onNavRepeterArreter: onNavRepeterArreter)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
        .padding(.vertical, 8)
        .autoFocuserSiBesoin(blocId: bloc.id, autoFocusId: $autoFocusId,
                              autoFocusOffset: $autoFocusOffset, cursorAt: $cursorAt, focused: $focused)
        .onChange(of: focused) { _, f in if f { onFocus?() } }
        .sheet(isPresented: $emojiPickerOuvert) {
            EmojiPickerSheet(selection: icon, recents: emojisRecents) { emoji in
                bloc.content = .quote(icon: emoji, text: bloc.spans)
                emojisRecents = enregistrerEmojiRecent(emoji)
                onSauvegarder()
            }
        }
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
    var onLongPressSelection: (() -> Void)?
    var onFocus: (() -> Void)?
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
                onLongPressSelection: onLongPressSelection,
                onNaviguerPrecedent: onNaviguerPrecedent,
                onNaviguerSuivant: onNaviguerSuivant,
                onNavRepeterArreter: onNavRepeterArreter)
        }
        .padding(.vertical, 2)
        .autoFocuserSiBesoin(blocId: bloc.id, autoFocusId: $autoFocusId,
                              autoFocusOffset: $autoFocusOffset, cursorAt: $cursorAt, focused: $focused)
        .onChange(of: focused) { _, f in if f { onFocus?() } }
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

// ── FAB document ──────────────────────────────────────────────────────────────

private struct BoutonActionDoc: View {
    let action: () -> Void
    @State private var impulsion = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.58)) { impulsion = true }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(.easeOut(duration: 0.18)) { impulsion = false }
            }
        } label: {
            ZStack {
                if impulsion {
                    Circle()
                        .fill(Color("SelectionTint").opacity(0.18))
                        .frame(width: 54, height: 54)
                        .transition(.scale.combined(with: .opacity))
                }
                Image(systemName: "pencil.and.outline")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .symbolEffect(.bounce, value: impulsion)
            }
            .frame(width: 54, height: 54)
            .contentShape(Circle())
        }
        .buttonStyle(BoutonActionDocStyle())
        .sensoryFeedback(.impact(flexibility: .soft), trigger: impulsion)
    }
}

private struct BoutonActionDocStyle: ButtonStyle {
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
