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

struct EditableBlock: Identifiable, Equatable {
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
    var active: Bool { timer != nil }

    func start(interval: TimeInterval = 0.12, _ step: @escaping () -> Void) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in step() }
    }

    func stop() {
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
    private let repeater = ActionRepeater()
    var isNavigating: Bool { repeater.active }

    // ── Undo / redo ─────────────────────────────────────────────────────
    // Capacité alignée sur CAPACITE_PAR_DEFAUT du back Rust (1000).
    let undoMgr = UndoManager()
    /// `canUndo` reflète aussi les bursts en cours : si l'utilisateur tape et
    /// déclenche undo avant la fin du burst (`burstInterval`), `vm.undo()` flush
    /// d'abord puis annule.
    var canUndo: Bool { undoMgr.canUndo || !blockBurstAnchor.isEmpty }
    var canRedo: Bool { undoMgr.canRedo }
    /// Snapshot du dernier titre persisté pour calculer l'inverse à enregistrer.
    private var lastPersistedTitle: String = ""

    // ── Burst undo pour la frappe ───────────────────────────────────────
    // Style Notes : une rafale continue de saveBlock sur le même bloc =
    // 1 seule étape d'undo. Pause de `burstInterval` → flush du burst.
    struct BlockSnapshot: Equatable {
        let content: BlockContentFfi
        let spans: [InlineTextFfi]
        let done: Bool
    }
    /// Dernière state stable connue par bloc (mise à jour à chaque flush ou
    /// mutation hors-burst). Sert d'anchor au démarrage du burst suivant.
    private var blockSnapshots: [String: BlockSnapshot] = [:]
    /// State pré-burst capturée au premier saveBlock du burst. C'est ce qu'on
    /// restaurera quand l'utilisateur fera undo.
    private var blockBurstAnchor: [String: BlockSnapshot] = [:]
    private var burstFlushWork: DispatchWorkItem?
    private var burstFlushBlockId: String?
    private let burstInterval: TimeInterval = 0.3

    private let api: ChaqaqApi

    init(docId: String, api: ChaqaqApi) {
        self.docId = docId
        self.api   = api
        undoMgr.levelsOfUndo = 1000
        // SwiftUI rafraîchit canUndo/canRedo via objectWillChange à chaque
        // mutation de la pile undo. On dispatch en async pour éviter de notifier
        // pendant un cycle de view update (warning « Publishing changes from
        // within view updates »), car NSUndoManagerCheckpoint peut être posté
        // synchrone depuis n'importe quel registerUndo, y compris ceux déclenchés
        // par un onChange/binding pendant le body.
        NotificationCenter.default.addObserver(
            forName: .NSUndoManagerCheckpoint,
            object: undoMgr,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
            }
        }
    }

    func undo() { flushAllBursts(); undoMgr.undo() }
    func redo() { flushAllBursts(); undoMgr.redo() }

    private func snapshotOf(_ block: EditableBlock) -> BlockSnapshot {
        BlockSnapshot(content: block.content, spans: block.spans, done: block.done)
    }

    /// Enregistre l'inverse d'une rafale de frappe : restaure l'anchor pré-burst.
    /// Auto-réenregistre redo via le pattern UndoManager (registerUndo pendant
    /// un undo → bascule sur la pile redo).
    func applyBlockSnapshot(blockId: String, snapshot snap: BlockSnapshot) {
        guard let idx = blocks.firstIndex(where: { $0.id == blockId }) else { return }
        let previous = snapshotOf(blocks[idx])
        blocks[idx] = EditableBlock(id: blockId,
                                    content: snap.content,
                                    spans: snap.spans,
                                    done: snap.done)
        persistBlockRaw(blocks[idx])
        blockSnapshots[blockId] = snap
        undoMgr.registerUndo(withTarget: self) { vm in
            vm.applyBlockSnapshot(blockId: blockId, snapshot: previous)
        }
    }

    /// Persiste un bloc sans toucher au burst ni à blockSnapshots. Utilisé par
    /// saveBlock (qui gère le burst à part) et par applyBlockSnapshot.
    private func persistBlockRaw(_ block: EditableBlock) {
        do {
            let new = block.content.withSpans(block.spans, done: block.done)
            let data = try JSONEncoder().encode(new)
            try api.updateBlock(docId: docId, blockId: block.id,
                                 contentJson: String(data: data, encoding: .utf8)!)
        } catch { errorMessage = error.localizedDescription }
    }

    /// Persistance pour les mutations hors frappe (toggle, icon, convert…).
    /// Flush d'abord le burst en cours sur ce bloc pour ne pas avaler la
    /// modification structurelle dans la rafale de typing.
    func persistBlock(_ block: EditableBlock) {
        flushBurst(blockId: block.id)
        persistBlockRaw(block)
        blockSnapshots[block.id] = snapshotOf(block)
    }

    /// Flush le burst d'un bloc : persiste le résultat et enregistre l'undo
    /// avec l'anchor capturé. Appelé par le timer du burst, sur switch de
    /// bloc, ou via `persistBlock` (mutation structurelle).
    private func flushBurst(blockId: String) {
        guard let anchor = blockBurstAnchor[blockId] else { return }
        let current = blockSnapshots[blockId]
        blockBurstAnchor.removeValue(forKey: blockId)
        if burstFlushBlockId == blockId {
            burstFlushBlockId = nil
            burstFlushWork?.cancel()
            burstFlushWork = nil
        }
        guard let current, anchor != current else { return }
        if let idx = blocks.firstIndex(where: { $0.id == blockId }) {
            persistBlockRaw(blocks[idx])
        }
        undoMgr.registerUndo(withTarget: self) { vm in
            vm.applyBlockSnapshot(blockId: blockId, snapshot: anchor)
        }
    }

    private func flushAllBursts() {
        burstFlushWork?.cancel()
        burstFlushWork = nil
        for id in Array(blockBurstAnchor.keys) { flushBurst(blockId: id) }
        burstFlushBlockId = nil
    }

    func load() {
        do {
            let json = try api.getDocumentJson(id: docId)
            guard let data = json.data(using: .utf8) else { return }
            let doc = try JSONDecoder().decode(DocumentFfi.self, from: data)
            title = doc.title.map(\.content).joined()
            lastPersistedTitle = title
            cover = doc.cover
            blocks = doc.blocks.map {
                EditableBlock(id: $0.id, content: $0.content,
                              spans: $0.content.spansOrEmpty,
                              done:  $0.content.isTodoDone)
            }
            // Initialise les snapshots stables pour le burst undo.
            blockSnapshots = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, snapshotOf($0)) })
            blockBurstAnchor.removeAll()
        } catch { errorMessage = error.localizedDescription }
    }

    func saveTitle() {
        let oldTitle = lastPersistedTitle
        let newTitle = title
        guard oldTitle != newTitle else { return }
        do {
            try api.updateDocumentTitle(id: docId, newTitle: newTitle)
            lastPersistedTitle = newTitle
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.title = oldTitle
                vm.saveTitle()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveCover(_ newCover: String?) {
        let oldCover = self.cover
        guard oldCover != newCover else {
            cover = newCover
            return
        }
        do {
            cover = newCover
            try api.updateDocumentCover(id: docId, cover: newCover)
            undoMgr.registerUndo(withTarget: self) { vm in vm.saveCover(oldCover) }
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

    /// Save appelé à chaque frappe (RichTextEditor → save() → onSaveSpans).
    /// Gère uniquement la state in-memory et le tracking du burst undo : la
    /// persistance SQLite est repoussée à `flushBurst` (1 write max par burst)
    /// pour éviter de saturer l'I/O à chaque caractère.
    func saveBlock(_ block: EditableBlock) {
        let id = block.id
        // Si on tape dans un autre bloc, on flush l'ancien burst (qui persiste).
        if let prevId = burstFlushBlockId, prevId != id {
            flushBurst(blockId: prevId)
        }
        // Démarrage du burst : on capture l'état pré-changement comme anchor.
        if blockBurstAnchor[id] == nil, let baseline = blockSnapshots[id] {
            blockBurstAnchor[id] = baseline
        }
        // Le snapshot stable suit la state actuelle (post-changement).
        blockSnapshots[id] = snapshotOf(block)
        burstFlushBlockId = id
        // Debounce : pas de saveBlock pendant burstInterval → flush + persist.
        burstFlushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushBurst(blockId: id)
        }
        burstFlushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + burstInterval, execute: work)
    }

    func saveBlock(id: String, spans: [InlineTextFfi]) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[idx].spans = spans
        saveBlock(blocks[idx])
    }

    func addBlock(type: NewBlockType, initialSpans: [InlineTextFfi] = [], afterId: String? = nil) {
        do {
            let content: BlockContentFfi
            switch type {
            case .text:      content = .text([])
            case .title1:     content = .heading(level: 1, text: [])
            case .title2:     content = .heading(level: 2, text: [])
            case .title3:     content = .heading(level: 3, text: [])
            case .quote:   content = .quote(icon: "", text: [])
            case .callout:    content = .quote(icon: "💡", text: [])
            case .todo:       content = .todo(done: false, text: [])
            case .divider: content = .divider
            }
            let data  = try JSONEncoder().encode(content)
            let newId = try api.addBlock(docId: docId,
                                            blockContentJson: String(data: data, encoding: .utf8)!)
            let newBlock = EditableBlock(id: newId, content: content, spans: initialSpans, done: false)

            if let afterId, let idx = blocks.firstIndex(where: { $0.id == afterId }) {
                blocks.insert(newBlock, at: idx + 1)
                try? api.reorderBlocks(docId: docId, order: blocks.map(\.id))
            } else {
                blocks.append(newBlock)
            }
            if !initialSpans.isEmpty { persistBlockRaw(newBlock) }
            blockSnapshots[newId] = snapshotOf(newBlock)
            autoFocusOffset = 0
            autoFocusId = newId
            // Undo : supprime le bloc qu'on vient de créer. deleteBlock enregistre
            // automatiquement le redo (réinsertion).
            undoMgr.registerUndo(withTarget: self) { vm in vm.deleteBlock(id: newId) }
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteBlock(id: String) {
        flushBurst(blockId: id)
        guard let block = blocks.first(where: { $0.id == id }),
              let index = blocks.firstIndex(where: { $0.id == id })
        else { return }
        do {
            try api.deleteBlock(docId: docId, blockId: id)
            blocks.removeAll { $0.id == id }
            blockSnapshots.removeValue(forKey: id)
            // Undo : réinsère le bloc à sa position. reinsertBlock enregistre
            // le redo (re-suppression du bloc nouvellement créé).
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.reinsertBlock(block, at: index)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Recrée un bloc supprimé : passe par l'API (nouveau UUID) puis réordonne
    /// pour le placer à sa position d'origine. Le UUID change entre undo cycles
    /// mais le contenu est préservé — comportement standard d'undo iOS.
    /// Focus auto sur le bloc restauré (curseur en fin de texte) — UX standard
    /// quand l'utilisateur undo une suppression.
    private func reinsertBlock(_ block: EditableBlock, at index: Int) {
        do {
            let content = block.content.withSpans(block.spans, done: block.done)
            let data = try JSONEncoder().encode(content)
            let newId = try api.addBlock(docId: docId,
                                         blockContentJson: String(data: data, encoding: .utf8)!)
            let recreated = EditableBlock(id: newId, content: content,
                                          spans: block.spans, done: block.done)
            let safeIndex = min(index, blocks.count)
            blocks.insert(recreated, at: safeIndex)
            try api.reorderBlocks(docId: docId, order: blocks.map(\.id))
            blockSnapshots[newId] = snapshotOf(recreated)
            autoFocusOffset = nil
            autoFocusId = newId
            // Redo : re-supprimer ce bloc.
            undoMgr.registerUndo(withTarget: self) { vm in vm.deleteBlock(id: newId) }
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteBlocks(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids { flushBurst(blockId: id) }
        // Snapshots avec index (triés croissant) pour restauration ordonnée.
        let snapshots: [(Int, EditableBlock)] = blocks.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { ($0.offset, $0.element) }
        do {
            for id in ids {
                try api.deleteBlock(docId: docId, blockId: id)
            }
            blocks.removeAll { ids.contains($0.id) }
            for id in ids { blockSnapshots.removeValue(forKey: id) }
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.undoMgr.beginUndoGrouping()
                for (index, block) in snapshots {
                    vm.reinsertBlock(block, at: index)
                }
                vm.undoMgr.endUndoGrouping()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Toggle done d'un bloc todo. Undo flippe à nouveau (s'auto-réenregistre).
    func toggleBlockDone(id: String) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[idx].done.toggle()
        persistBlock(blocks[idx])
        undoMgr.registerUndo(withTarget: self) { vm in vm.toggleBlockDone(id: id) }
    }

    /// Change l'icône d'un bloc callout. Undo restaure l'ancienne icône.
    func updateBlockIcon(id: String, icon: String) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        guard case .quote(let oldIcon, _) = blocks[idx].content, oldIcon != icon else { return }
        blocks[idx].content = .quote(icon: icon, text: blocks[idx].spans)
        persistBlock(blocks[idx])
        undoMgr.registerUndo(withTarget: self) { vm in
            vm.updateBlockIcon(id: id, icon: oldIcon)
        }
    }

    /// Convertit le contenu d'un bloc (markdown shortcut : text → heading, etc.).
    /// Undo restaure l'ancien content + spans, redo réapplique.
    func convertBlockContent(id: String, to newContent: BlockContentFfi) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        let oldContent = blocks[idx].content
        let oldSpans = blocks[idx].spans
        let oldDone = blocks[idx].done
        blocks[idx].content = newContent
        blocks[idx].spans = []
        blocks[idx].done = false
        persistBlock(blocks[idx])
        undoMgr.registerUndo(withTarget: self) { vm in
            guard let i = vm.blocks.firstIndex(where: { $0.id == id }) else { return }
            vm.blocks[i].content = oldContent
            vm.blocks[i].spans = oldSpans
            vm.blocks[i].done = oldDone
            vm.persistBlock(vm.blocks[i])
            vm.undoMgr.registerUndo(withTarget: vm) { vm in
                vm.convertBlockContent(id: id, to: newContent)
            }
        }
    }

    func startNavigationRepeat(from: String, next: Bool) {
        guard !repeater.active else { return }
        focusedBlockId = from
        repeater.start { [weak self] in self?.navigationStep(next: next) }
    }

    func stopNavigationRepeat() {
        repeater.stop()
        focusedBlockId = nil
    }

    private func navigationStep(next: Bool) {
        guard let cid = focusedBlockId,
              let idx = blocks.firstIndex(where: { $0.id == cid }) else { stopNavigationRepeat(); return }
        if next {
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
        let oldOrder = blocks.map(\.id)
        blocks.move(fromOffsets: from, toOffset: to)
        let newOrder = blocks.map(\.id)
        guard oldOrder != newOrder else { return }
        try? api.reorderBlocks(docId: docId, order: newOrder)
        undoMgr.registerUndo(withTarget: self) { vm in vm.applyBlockOrder(oldOrder) }
    }

    /// Applique un ordre de blocs (utilisé par l'undo/redo de moveBlock).
    private func applyBlockOrder(_ order: [String]) {
        let oldOrder = blocks.map(\.id)
        let lookup = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        blocks = order.compactMap { lookup[$0] }
        try? api.reorderBlocks(docId: docId, order: order)
        undoMgr.registerUndo(withTarget: self) { vm in vm.applyBlockOrder(oldOrder) }
    }
}

// ── Types de blocks ────────────────────────────────────────────────────────────

enum NewBlockType: String, CaseIterable, Identifiable {
    case text = "Texte", title1 = "Titre 1", title2 = "Titre 2", title3 = "Titre 3"
    case quote = "Citation", callout = "Callout", todo = "À faire", divider = "Séparateur"
    var id: String { rawValue }
    var icone: String {
        switch self {
        case .text:      return "text.alignleft"
        case .title1:     return "1.circle.fill"
        case .title2:     return "2.circle"
        case .title3:     return "3.circle"
        case .quote:   return "quote.bubble"
        case .callout:    return "lightbulb"
        case .todo:       return "checkmark.square"
        case .divider: return "minus"
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
                         onNewBlock: { vm.addBlock(type: .text) })
                .disabled(documentLocked)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
                .moveDisabled(true)
                .deleteDisabled(true)

            if vm.blocks.isEmpty && !documentLocked {
                EmptyEditorState { vm.addBlock(type: .text) }
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
                                vm.addBlock(type: .text, initialSpans: afterSpans, afterId: block.id)
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
                                    vm.startNavigationRepeat(from: nid, next: false)
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
                                vm.startNavigationRepeat(from: nid, next: true)
                            },
                            onStopNavigationRepeat: { vm.stopNavigationRepeat() },
                            onLongPressSelection: { selectFromLongPress(block.id) },
                            onFocus: { vm.activeBlockId = block.id },
                            onToggleDone: { vm.toggleBlockDone(id: block.id) },
                            onChangeIcon: { icon in vm.updateBlockIcon(id: block.id, icon: icon) },
                            onConvertContent: { content in vm.convertBlockContent(id: block.id, to: content) },
                            onUndo: { vm.undo() },
                            onRedo: { vm.redo() },
                            canUndoProvider: { vm.canUndo },
                            canRedoProvider: { vm.canRedo }
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
        .onAppear { vm.load() }
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

        // Undo / redo en bas-gauche, miroir du FAB. Pill unique style lock/réordo
        // de la barre de navigation : un seul fond glass capsule pour les deux.
        if !documentLocked && editMode == .inactive && !keyboardVisible {
            UndoRedoPill(canUndo: vm.canUndo, canRedo: vm.canRedo,
                         onUndo: { vm.undo() }, onRedo: { vm.redo() })
                .padding(.leading, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            Label(cover == nil ? "Ajouter une couverture" : "Changer la couverture", systemImage: "photo")
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
        TitleEditor(text: $title, isFocused: $focused,
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
    @Binding var text: String
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
        tv.attributedText = text.isEmpty
            ? context.coordinator.placeholderAttr()
            : NSAttributedString(string: text, attributes: [.font: police, .foregroundColor: UIColor.label])
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
            tv.attributedText = text.isEmpty
                ? context.coordinator.placeholderAttr()
                : NSAttributedString(string: text, attributes: [.font: police, .foregroundColor: UIColor.label])
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
            parent.text = tv.text ?? ""
            parent.onSave()
            if parent.text.isEmpty { tv.attributedText = placeholderAttr() }
        }

        func textViewDidChange(_ tv: UITextView) {
            guard let text = tv.text else { return }
            if let idx = text.firstIndex(of: "\n") {
                tv.text = String(text[text.startIndex..<idx])
                parent.text = tv.text
                parent.onSave()
                parent.onNewBlock()
                return
            }
            parent.text = text
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
    // Mutations atomiques avec undo : passent par le VM (toggleBlockDone, etc.)
    // pour que l'inverse soit enregistré sur la pile undo.
    var onToggleDone: (() -> Void)? = nil
    var onChangeIcon: ((String) -> Void)? = nil
    var onConvertContent: ((BlockContentFfi) -> Void)? = nil
    // Undo/redo exposés dans la pill clavier. Closures live → le Coordinator
    // les rappelle dans textViewDidChange/textViewDidChangeSelection + updateUIView,
    // ce qui couvre les cas frappe, undo, redo, sélection.
    var onUndo: (() -> Void)? = nil
    var onRedo: (() -> Void)? = nil
    var canUndoProvider: (() -> Bool)? = nil
    var canRedoProvider: (() -> Bool)? = nil
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
            onConvert: convertible ? { content in cb.onConvertContent?(content) } : nil,
            onLongPressSelection: cb.onLongPressSelection,
            onNavigatePrevious: cb.onNavigatePrevious,
            onNavigateNext: cb.onNavigateNext,
            onStopNavigationRepeat: cb.onStopNavigationRepeat,
            onUndo: cb.onUndo,
            onRedo: cb.onRedo,
            canUndoProvider: cb.canUndoProvider,
            canRedoProvider: cb.canRedoProvider)
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
                recentEmojis = saveRecentEmoji(emoji)
                // Passe par le VM pour bénéficier de l'undo.
                cb.onChangeIcon?(emoji)
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
                cb.onToggleDone?()
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

// ── Undo / Redo ───────────────────────────────────────────────────────────────
// Pill unique avec deux icônes — visuellement identique à la pill lock/réordo
// de la nav bar : un seul fond glass capsule, chaque icône reste tappable.

private struct UndoRedoPill: View {
    let canUndo: Bool
    let canRedo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            iconButton(icon: "arrow.uturn.backward", enabled: canUndo, action: onUndo)
            iconButton(icon: "arrow.uturn.forward",  enabled: canRedo, action: onRedo)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: canUndo)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: canRedo)
    }

    private func iconButton(icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.45))
                .frame(width: 54, height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
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
