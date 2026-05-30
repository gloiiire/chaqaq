import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// ── Auto-focus (extension partagée) ──────────────────────────────────────────

private extension View {
    func autoFocusIfNeeded(blockId: String,
                              autoFocusId: Binding<String?>,
                              autoFocusOffset: Binding<Int?>,
                              cursorAt: Binding<Int?>,
                              focused: Binding<Bool>) -> some View {
        self
            .onAppear {
                guard autoFocusId.wrappedValue == blockId else { return }
                autoFocusId.wrappedValue = nil
                let off = autoFocusOffset.wrappedValue
                autoFocusOffset.wrappedValue = nil
                DispatchQueue.main.async { cursorAt.wrappedValue = off; focused.wrappedValue = true }
            }
            .onChange(of: autoFocusId.wrappedValue) { _, newId in
                guard newId == blockId else { return }
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
    var plainText: String { spans.map(\.content).joined() }
}

// ── Répéteur d'action ─────────────────────────────────────────────────────────
// Répète une closure à intervalle régulier (maintien d'une touche de navigation).
// Isole la mécanique du Timer hors du view model.

final class ActionRepeater {
    private var timer: Timer?
    var actif: Bool { timer != nil }

    func demarrer(intervalle: TimeInterval = 0.12, _ pas: @escaping () -> Void) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: intervalle, repeats: true) { _ in pas() }
    }

    func arreter() {
        timer?.invalidate()
        timer = nil
    }
}

// ── View Model ────────────────────────────────────────────────────────────────

@MainActor
final class DocumentViewModel: ObservableObject {
    let docId: String
    @Published var title: String = ""
    @Published var cover: String?
    @Published var blocks: [EditableBlock] = []
    @Published var errorMessage: String?
    @Published var autoFocusId: String?
    @Published var autoFocusOffset: Int? = nil
    var activeBlockId: String? = nil
    private var focusedBlockId: String? = nil
    private let repeteur = ActionRepeater()
    var isNavigating: Bool { repeteur.actif }

    private let api: ChaqaqApi

    init(docId: String, api: ChaqaqApi) {
        self.docId = docId
        self.api   = api
    }

    func charger() {
        do {
            let json = try api.getDocumentJson(id: docId)
            guard let data = json.data(using: .utf8) else { return }
            let doc = try JSONDecoder().decode(DocumentFfi.self, from: data)
            title = doc.title.map(\.content).joined()
            cover = doc.cover
            blocks = doc.blocks.map {
                EditableBlock(id: $0.id, content: $0.content,
                              spans: $0.content.spansOrEmpty,
                              done:  $0.content.isTodoDone)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveTitle() {
        try? api.updateDocumentTitle(id: docId, newTitle: title)
    }

    func saveCover(_ newCover: String?) {
        do {
            cover = newCover
            try api.updateDocumentCover(id: docId, cover: newCover)
        } catch { errorMessage = error.localizedDescription }
    }

    func saveCoverImage(data: Data, fileExtension: String = "jpg") {
        do {
            let nom = try Self.writeCoverImage(data: data, docId: docId, fileExtension: fileExtension)
            saveCover(nom)
        } catch { errorMessage = error.localizedDescription }
    }

    func saveCoverImageFromFile(_ url: URL) {
        let acces = url.startAccessingSecurityScopedResource()
        defer {
            if acces { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            let ext = Self.imageExtension(url.pathExtension)
            let nom = try Self.writeCoverImage(data: data, docId: docId, fileExtension: ext)
            saveCover(nom)
        } catch { errorMessage = error.localizedDescription }
    }

    private static func writeCoverImage(data: Data, docId: String, fileExtension: String) throws -> String {
        let directory = try coversDirectory()
        let nom = docId.replacingOccurrences(of: "/", with: "-") + "." + fileExtension
        let url = directory.appendingPathComponent(nom)
        try data.write(to: url, options: .atomic)
        return nom
    }

    fileprivate static func coversDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Chaqaq/Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func imageExtension(_ ext: String) -> String {
        let cleaned = ext.lowercased()
        return ["jpg", "jpeg", "png", "heic", "webp"].contains(cleaned) ? cleaned : "jpg"
    }

    func saveBlock(_ block: EditableBlock) {
        do {
            let new = block.content.withSpans(block.spans, done: block.done)
            let data    = try JSONEncoder().encode(new)
            try api.updateBlock(docId: docId, blockId: block.id,
                                 contentJson: String(data: data, encoding: .utf8)!)
        } catch { errorMessage = error.localizedDescription }
    }

    func saveBlock(id: String, spans: [InlineTextFfi]) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[idx].spans = spans
        saveBlock(blocks[idx])
    }

    func addBlock(type: NewBlockType, spansInitiaux: [InlineTextFfi] = [], afterId: String? = nil) {
        do {
            let content: BlockContentFfi
            switch type {
            case .texte:      content = .text([])
            case .title1:     content = .heading(level: 1, text: [])
            case .title2:     content = .heading(level: 2, text: [])
            case .title3:     content = .heading(level: 3, text: [])
            case .citation:   content = .quote(icon: "", text: [])
            case .callout:    content = .quote(icon: "💡", text: [])
            case .todo:       content = .todo(done: false, text: [])
            case .separateur: content = .divider
            }
            let data  = try JSONEncoder().encode(content)
            let newId = try api.addBlock(docId: docId,
                                            blockContentJson: String(data: data, encoding: .utf8)!)
            let newBloc = EditableBlock(id: newId, content: content, spans: spansInitiaux, done: false)

            if let afterId, let idx = blocks.firstIndex(where: { $0.id == afterId }) {
                blocks.insert(newBloc, at: idx + 1)
                try? api.reorderBlocks(docId: docId, order: blocks.map(\.id))
            } else {
                blocks.append(newBloc)
            }
            if !spansInitiaux.isEmpty { saveBlock(newBloc) }
            autoFocusOffset = 0
            autoFocusId = newId
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteBlock(id: String) {
        do {
            try api.deleteBlock(docId: docId, blockId: id)
            blocks.removeAll { $0.id == id }
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteBlocks(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        do {
            for id in ids {
                try api.deleteBlock(docId: docId, blockId: id)
            }
            blocks.removeAll { ids.contains($0.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    func startNavigationRepeat(depuis: String, suivant: Bool) {
        guard !repeteur.actif else { return }
        focusedBlockId = depuis
        repeteur.demarrer { [weak self] in self?.navigationStep(suivant: suivant) }
    }

    func stopNavigationRepeat() {
        repeteur.arreter()
        focusedBlockId = nil
    }

    private func navigationStep(suivant: Bool) {
        guard let cid = focusedBlockId,
              let idx = blocks.firstIndex(where: { $0.id == cid }) else { stopNavigationRepeat(); return }
        if suivant {
            guard idx < blocks.count - 1 else { stopNavigationRepeat(); return }
            let nid = blocks[idx + 1].id
            autoFocusOffset = 0; focusedBlockId = nid; autoFocusId = nid
        } else {
            guard idx > 0 else { stopNavigationRepeat(); return }
            let nid = blocks[idx - 1].id
            autoFocusOffset = nil; focusedBlockId = nid; autoFocusId = nid
        }
    }

    func moveBlock(from: IndexSet, to: Int) {
        blocks.move(fromOffsets: from, toOffset: to)
        try? api.reorderBlocks(docId: docId, order: blocks.map(\.id))
    }
}

// ── Types de blocks ────────────────────────────────────────────────────────────

enum NewBlockType: String, CaseIterable, Identifiable {
    case texte = "Texte", title1 = "Titre 1", title2 = "Titre 2", title3 = "Titre 3"
    case citation = "Citation", callout = "Callout", todo = "À faire", separateur = "Séparateur"
    var id: String { rawValue }
    var icone: String {
        switch self {
        case .texte:      return "text.alignleft"
        case .title1:     return "1.circle.fill"
        case .title2:     return "2.circle"
        case .title3:     return "3.circle"
        case .citation:   return "quote.bubble"
        case .callout:    return "lightbulb"
        case .todo:       return "checkmark.square"
        case .separateur: return "minus"
        }
    }
}

// ── Helpers emoji persistance ─────────────────────────────────────────────────

private let recentEmojisKey = "document.icon.recentEmojis"

private func loadRecentEmojis() -> [String] {
    UserDefaults.standard.stringArray(forKey: recentEmojisKey) ?? []
}

@discardableResult
private func saveRecentEmoji(_ emoji: String) -> [String] {
    let existants = UserDefaults.standard.stringArray(forKey: recentEmojisKey) ?? []
    let liste = Array(([emoji] + existants.filter { $0 != emoji }).prefix(6))
    UserDefaults.standard.set(liste, forKey: recentEmojisKey)
    return liste
}

// ── Vue document ──────────────────────────────────────────────────────────────

struct DocumentView: View {
    @StateObject private var vm: DocumentViewModel
    @State private var showingBlockPicker = false
    @State private var editMode: EditMode = .inactive
    @State private var focusTitle = false
    @State private var titleInNavBar = false
    @State private var documentLocked: Bool
    @State private var documentIcon: String?
    @State private var recentEmojis: [String]
    @State private var selectedBlocks: Set<String> = []
    @State private var keyboardVisible = false
    private let lockKey: String
    private let iconKey: String

    var onDisappear: (() -> Void)? = nil

    init(docId: String, api: ChaqaqApi, onDisappear: (() -> Void)? = nil) {
        let lockKey = Self.lockKeyFor(docId: docId)
        let iconKey = Self.iconKeyFor(docId: docId)
        _vm = StateObject(wrappedValue: DocumentViewModel(docId: docId, api: api))
        _documentLocked = State(initialValue: UserDefaults.standard.bool(forKey: lockKey))
        _documentIcon = State(initialValue: UserDefaults.standard.string(forKey: iconKey))
        _recentEmojis = State(initialValue: loadRecentEmojis())
        self.lockKey = lockKey
        self.iconKey = iconKey
        self.onDisappear = onDisappear
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
        List {
            DocumentDecorView(
                cover: vm.cover,
                icone: documentIcon,
                recentEmojis: recentEmojis,
                verrouille: documentLocked,
                onCouverture: { vm.saveCover($0) },
                onImageData: { data in vm.saveCoverImage(data: data) },
                onImageFichier: { url in vm.saveCoverImageFromFile(url) },
                onIcone: { nouvelleIcone in
                    documentIcon = nouvelleIcone
                    if let nouvelleIcone {
                        UserDefaults.standard.set(nouvelleIcone, forKey: iconKey)
                        recentEmojis = saveRecentEmoji(nouvelleIcone)
                    } else {
                        UserDefaults.standard.removeObject(forKey: iconKey)
                    }
                }
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .moveDisabled(true)
            .deleteDisabled(true)

            DocumentTitleView(title: $vm.title, focusDemande: $focusTitle,
                         onSave: vm.saveTitle,
                         onNewBlock: { vm.addBlock(type: .texte) })
                .disabled(documentLocked)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
                .moveDisabled(true)
                .deleteDisabled(true)

            if vm.blocks.isEmpty && !documentLocked {
                EmptyEditorState { vm.addBlock(type: .texte) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .moveDisabled(true)
                    .deleteDisabled(true)
            }

            ForEach($vm.blocks) { $block in
                HStack(alignment: .center, spacing: 10) {
                    if editMode == .active {
                        selectionButton(block.id)
                    }

                    BlockRowView(
                        block: $block,
                        autoFocusId: $vm.autoFocusId,
                        autoFocusOffset: $vm.autoFocusOffset,
                        cb: BlockCallbacks(
                            onSave: {
                                guard let idx = vm.blocks.firstIndex(where: { $0.id == block.id }) else { return }
                                vm.saveBlock(vm.blocks[idx])
                            },
                            onSaveSpans: { spans in
                                vm.saveBlock(id: block.id, spans: spans)
                            },
                            onDelete: {
                                if let idx = vm.blocks.firstIndex(where: { $0.id == block.id }) {
                                    if idx > 0 {
                                        let prevId = vm.blocks[idx - 1].id
                                        vm.deleteBlock(id: block.id)
                                        vm.autoFocusId = prevId
                                    } else {
                                        vm.deleteBlock(id: block.id)
                                        focusTitle = true
                                    }
                                }
                            },
                            onNewBlock: { afterSpans in
                                vm.addBlock(type: .texte, spansInitiaux: afterSpans, afterId: block.id)
                            },
                            onMerge: vm.blocks.first?.id == block.id ? nil : { spansAMerger in
                                guard let idx = vm.blocks.firstIndex(where: { $0.id == block.id }), idx > 0 else { return }
                                let prevIdx      = idx - 1
                                let prevId       = vm.blocks[prevIdx].id
                                let offsetFusion = vm.blocks[prevIdx].spans.map(\.content).joined().count
                                vm.blocks[prevIdx].spans += spansAMerger
                                vm.saveBlock(vm.blocks[prevIdx])
                                vm.deleteBlock(id: block.id)
                                vm.autoFocusOffset = offsetFusion
                                vm.autoFocusId     = prevId
                            },
                            onNavigatePrevious: {
                                guard !vm.isNavigating else { return }
                                guard let idx = vm.blocks.firstIndex(where: { $0.id == block.id }) else { return }
                                if idx > 0 {
                                    let nid = vm.blocks[idx - 1].id
                                    vm.autoFocusOffset = nil
                                    vm.autoFocusId = nid
                                    vm.startNavigationRepeat(depuis: nid, suivant: false)
                                } else {
                                    focusTitle = true
                                }
                            },
                            onNavigateNext: {
                                guard !vm.isNavigating else { return }
                                guard let idx = vm.blocks.firstIndex(where: { $0.id == block.id }),
                                      idx < vm.blocks.count - 1 else { return }
                                let nid = vm.blocks[idx + 1].id
                                vm.autoFocusOffset = 0
                                vm.autoFocusId = nid
                                vm.startNavigationRepeat(depuis: nid, suivant: true)
                            },
                            onStopNavigationRepeat: { vm.stopNavigationRepeat() },
                            onLongPressSelection: { selectFromLongPress(block.id) },
                            onFocus: { vm.activeBlockId = block.id }
                        )
                    )
                    .disabled(documentLocked || editMode == .active)
                    .allowsHitTesting(!documentLocked && editMode != .active)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if editMode == .active {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            toggleSelection(block.id)
                        }
                    }
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                        selectFromLongPress(block.id)
                    }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .swipeActions(edge: .trailing) {
                    if !documentLocked && editMode != .active {
                        Button(role: .destructive) { vm.deleteBlock(id: block.id) } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            }
            .onMove(perform: vm.moveBlock)

            if !documentLocked {
                AddBlockButton { showingBlockPicker = true }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 40, trailing: 20))
                    .moveDisabled(true)
                    .deleteDisabled(true)
            }
        }
        .listStyle(.plain)
        .ignoresSafeArea(.container, edges: vm.cover == nil ? [] : .top)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, offset in
            withAnimation(.easeInOut(duration: 0.15)) { titleInNavBar = offset > 60 }
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.editMode, $editMode)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(vm.cover == nil ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(vm.cover == nil ? nil : .dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(vm.title.isEmpty ? "Sans titre" : vm.title)
                    .font(.headline)
                    .opacity(titleInNavBar ? 1 : 0)
                    .offset(y: titleInNavBar ? 0 : 8)
                    .animation(.easeOut(duration: 0.2), value: titleInNavBar)
            }
            if editMode == .active && !selectedBlocks.isEmpty && !documentLocked {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        deleteBlocksSelectionnes()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Supprimer les blocs sélectionnés")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let newVerrouillage = !documentLocked
                    withAnimation(.easeInOut(duration: 0.15)) {
                        documentLocked = newVerrouillage
                        if documentLocked {
                            editMode = .inactive
                            selectedBlocks.removeAll()
                            focusTitle = false
                            showingBlockPicker = false
                            vm.stopNavigationRepeat()
                        }
                    }
                    UserDefaults.standard.set(newVerrouillage, forKey: lockKey)
                } label: {
                    Image(systemName: documentLocked ? "lock.fill" : "lock.open.fill")
                }
                .accessibilityLabel(documentLocked ? "Déverrouiller le document" : "Verrouiller le document")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation {
                        editMode = editMode == .active ? .inactive : .active
                        if editMode != .active { selectedBlocks.removeAll() }
                    }
                } label: {
                    Image(systemName: editMode == .active ? "checkmark" : "arrow.up.arrow.down")
                }
                .disabled(documentLocked)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { keyboardVisible = false }
        }
        .onAppear { vm.charger() }
        .onDisappear { vm.saveTitle(); onDisappear?() }
        .sheet(isPresented: $showingBlockPicker) {
            BlockPickerSheet { type in vm.addBlock(type: type, afterId: vm.activeBlockId) }
        }
        .alert("Erreur", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }

        if !documentLocked && editMode == .inactive && !keyboardVisible {
            FloatingButton(icon: "pencil.and.outline") { showingBlockPicker = true }
                .padding(.trailing, 24)
                .padding(.bottom, 32)
                .transition(.scale.combined(with: .opacity))
        }
        } // fin ZStack
    }

    private func selectionButton(_ id: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                toggleSelection(id)
            }
        } label: {
            Image(systemName: selectedBlocks.contains(id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selectedBlocks.contains(id) ? Color("SelectionTint") : .secondary)
                .frame(width: 28, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleSelection(_ id: String) {
        if selectedBlocks.contains(id) {
            selectedBlocks.remove(id)
        } else {
            selectedBlocks.insert(id)
        }
    }

    private func selectFromLongPress(_ id: String) {
        guard !documentLocked else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            editMode = .active
            selectedBlocks.insert(id)
            focusTitle = false
            vm.stopNavigationRepeat()
        }
    }

    private func deleteBlocksSelectionnes() {
        let ids = selectedBlocks
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedBlocks.removeAll()
            vm.deleteBlocks(ids: ids)
        }
    }

    private static func lockKeyFor(docId: String) -> String {
        "document.locked.\(docId)"
    }

    private static func iconKeyFor(docId: String) -> String {
        "document.icon.\(docId)"
    }

}

// ── Cover + icône ─────────────────────────────────────────────────────────────

private struct DocumentDecorView: View {
    let cover: String?
    let icone: String?
    let recentEmojis: [String]
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
            if let coverId = cover {
                cover(coverId)
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
                .padding(.top, cover == nil && icone == nil ? 12 : 50)
            } else if cover != nil {
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
            EmojiPickerSheet(selection: icone, recents: recentEmojis) { emoji in
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
            Label(cover == nil ? "Ajouter une cover" : "Changer la cover", systemImage: "photo")
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
        if cover != nil {
            Divider()
            Button(role: .destructive) { onCouverture(nil) } label: {
                Label("Retirer la cover", systemImage: "trash")
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
        if let image = coverImage(id) {
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

    private func coverImage(_ id: String) -> UIImage? {
        if !id.hasPrefix("file://") && !id.hasPrefix("cover.") {
            guard let directory = try? DocumentViewModel.coversDirectory() else { return nil }
            return UIImage(contentsOfFile: directory.appendingPathComponent(id).path)
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
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Annuler")
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

private struct DocumentTitleView: View {
    @Binding var title: String
    @Binding var focusDemande: Bool
    let onSave: () -> Void
    let onNewBlock: () -> Void
    @State private var focused = false

    var body: some View {
        TitleEditor(texte: $title, isFocused: $focused,
                    onSave: onSave, onNewBlock: onNewBlock)
            .onChange(of: focusDemande) { _, demande in
                if demande {
                    focusDemande = false
                    DispatchQueue.main.async { focused = true }
                }
            }
    }
}

private struct TitleEditor: UIViewRepresentable {
    @Binding var texte: String
    @Binding var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    let onSave: () -> Void
    let onNewBlock: () -> Void

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
        if !context.coordinator.isEditing {
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
        var parent: TitleEditor
        weak var tv: ExpandingTextView?
        var isEditing = false

        init(parent: TitleEditor) { self.parent = parent }

        func placeholderAttr() -> NSAttributedString {
            NSAttributedString(string: "Sans titre",
                               attributes: [.font: parent.police, .foregroundColor: UIColor.tertiaryLabel])
        }

        func textViewDidBeginEditing(_ tv: UITextView) {
            isEditing = true
            parent.isFocused = true
            if tv.textColor == .tertiaryLabel {
                tv.attributedText = NSAttributedString(string: "",
                    attributes: [.font: parent.police, .foregroundColor: UIColor.label])
            }
            tv.typingAttributes = [.font: parent.police, .foregroundColor: UIColor.label]
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            isEditing = false
            parent.isFocused = false
            parent.texte = tv.text ?? ""
            parent.onSave()
            if parent.texte.isEmpty { tv.attributedText = placeholderAttr() }
        }

        func textViewDidChange(_ tv: UITextView) {
            guard let texte = tv.text else { return }
            if let idx = texte.firstIndex(of: "\n") {
                tv.text = String(texte[texte.startIndex..<idx])
                parent.texte = tv.text
                parent.onSave()
                parent.onNewBlock()
                return
            }
            parent.texte = texte
        }
    }
}

// ── État vide cliquable ───────────────────────────────────────────────────────

private struct EmptyEditorState: View {
    let onBegin: () -> Void
    @State private var focused = false

    var body: some View {
        RichTextEditor(
            spans: .constant([]),
            isFocused: $focused,
            placeholder: "Commence à écrire…",
            onSave: nil,
            onNewBlock: nil,
            onDeleteBloc: nil,
            onConvert: nil
        )
        .onChange(of: focused) { _, estFocus in
            if estFocus { onBegin() }
        }
    }
}

// ── Callbacks d'édition d'un block ─────────────────────────────────────────────
// Regroupe les closures partagées par tous les types de blocks pour éviter de les
// répéter dans chaque RowView et dans BlockRowView.

struct BlockCallbacks {
    var onSave: () -> Void
    var onSaveSpans: ([InlineTextFfi]) -> Void
    var onDelete: () -> Void
    var onNewBlock: ([InlineTextFfi]) -> Void
    var onMerge: (([InlineTextFfi]) -> Void)? = nil
    var onNavigatePrevious: (() -> Void)? = nil
    var onNavigateNext: (() -> Void)? = nil
    var onStopNavigationRepeat: (() -> Void)? = nil
    var onLongPressSelection: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil
}

// ── Éditeur de texte commun à tous les blocks ──────────────────────────────────
// Câblage unique du RichTextEditor + auto-focus + détection de focus. Chaque
// RowView ne fournit que placeholder, fonte, décor et options spécifiques.

private struct BlockTextEditor: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let placeholder: String
    let baseFont: UIFont
    var extraAttrs: [NSAttributedString.Key: Any]? = nil
    var convertible: Bool = true
    let cb: BlockCallbacks
    @State private var focused = false
    @State private var cursorAt: Int?

    var body: some View {
        RichTextEditor(
            spans: $block.spans,
            isFocused: $focused,
            placeholder: placeholder,
            baseFont: baseFont,
            extraAttrs: extraAttrs,
            focusCursorAt: cursorAt,
            onSave: cb.onSave,
            onSaveSpans: cb.onSaveSpans,
            onNewBlock: cb.onNewBlock,
            onDeleteBloc: cb.onDelete,
            onMergeAvecPrecedent: cb.onMerge,
            onConvert: convertible ? { content in block.content = content; block.spans = []; cb.onSave() } : nil,
            onLongPressSelection: cb.onLongPressSelection,
            onNavigatePrevious: cb.onNavigatePrevious,
            onNavigateNext: cb.onNavigateNext,
            onStopNavigationRepeat: cb.onStopNavigationRepeat)
        .autoFocusIfNeeded(blockId: block.id, autoFocusId: $autoFocusId,
                              autoFocusOffset: $autoFocusOffset, cursorAt: $cursorAt, focused: $focused)
        .onChange(of: focused) { _, f in if f { cb.onFocus?() } }
    }
}

// ── Ligne de block ─────────────────────────────────────────────────────────────

private struct BlockRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks

    var body: some View {
        Group {
            switch block.content {
            case .text:
                TextRowView(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset, cb: cb)
            case .heading(let level, _):
                HeadingRowView(block: $block, level: level, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset, cb: cb)
            case .quote(let icon, _):
                if icon.isEmpty {
                    QuoteRowView(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset, cb: cb)
                } else {
                    CalloutRowView(block: $block, icon: icon, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset, cb: cb)
                }
            case .todo:
                TodoRowView(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset, cb: cb)
            case .divider:
                Divider().padding(.vertical, 12)
            default:
                EmptyView()
            }
        }
        .contextMenu {
            Button(role: .destructive, action: cb.onDelete) {
                Label("Supprimer le bloc", systemImage: "trash")
            }
        }
    }
}

// ── Texte ─────────────────────────────────────────────────────────────────────

private struct TextRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks

    var body: some View {
        BlockTextEditor(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                       placeholder: "Texte…", baseFont: .preferredFont(forTextStyle: .body), cb: cb)
    }
}

// ── Heading ───────────────────────────────────────────────────────────────────

private struct HeadingRowView: View {
    @Binding var block: EditableBlock
    let level: Int
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks

    private var uiFont: UIFont {
        switch level {
        case 1:  return .systemFont(ofSize: 26, weight: .bold)
        case 2:  return .systemFont(ofSize: 22, weight: .semibold)
        default: return .systemFont(ofSize: 18, weight: .semibold)
        }
    }

    var body: some View {
        BlockTextEditor(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                       placeholder: "Titre…", baseFont: uiFont, cb: cb)
            .padding(.top, level == 1 ? 16 : 10)
            .padding(.bottom, 4)
    }
}

// ── Citation ──────────────────────────────────────────────────────────────────

private struct QuoteRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3)
                .padding(.vertical, 6)
            BlockTextEditor(
                block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                placeholder: "Citation…",
                baseFont: .italicSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize),
                cb: cb)
            .padding(.leading, 14)
        }
        .padding(.vertical, 4)
    }
}

// ── Callout ───────────────────────────────────────────────────────────────────

private struct CalloutRowView: View {
    @Binding var block: EditableBlock
    let icon: String
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks
    @State private var emojiPickerOuvert = false
    @State private var recentEmojis = loadRecentEmojis()

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

            BlockTextEditor(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                           placeholder: "Callout…", baseFont: .preferredFont(forTextStyle: .body), cb: cb)
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
        .sheet(isPresented: $emojiPickerOuvert) {
            EmojiPickerSheet(selection: icon, recents: recentEmojis) { emoji in
                block.content = .quote(icon: emoji, text: block.spans)
                recentEmojis = saveRecentEmoji(emoji)
                cb.onSave()
            }
        }
    }
}

// ── Todo ──────────────────────────────────────────────────────────────────────

private struct TodoRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks

    private var checkedAttrs: [NSAttributedString.Key: Any]? {
        block.done ? [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: UIColor.secondaryLabel
        ] : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                block.done.toggle()
                cb.onSave()
            } label: {
                Image(systemName: block.done ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(block.done ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            BlockTextEditor(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                           placeholder: "À faire…", baseFont: .preferredFont(forTextStyle: .body),
                           extraAttrs: checkedAttrs, convertible: false, cb: cb)
        }
        .padding(.vertical, 2)
    }
}

// ── Bouton ajouter ────────────────────────────────────────────────────────────

private struct AddBlockButton: View {
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

private struct BlockPickerSheet: View {
    let onSelect: (NewBlockType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(NewBlockType.allCases) { type in
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
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Annuler")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
