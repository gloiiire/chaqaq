import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// ── Auto-focus shared extension ───────────────────────────────────────────────

private extension View {
    /// Triggers focus and optionally places the cursor at `autoFocusOffset` when
    /// `autoFocusId` matches `blockId`. Works both on `.onAppear` and on subsequent
    /// `onChange` updates (e.g. after undo reinsertion).
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

// ── Editable model ────────────────────────────────────────────────────────────

/// In-memory representation of a block being edited. Holds a snapshot of content,
/// spans, and done-state so the UI can update optimistically without waiting for SQLite.
struct EditableBlock: Identifiable, Equatable {
    let id: String
    var content: BlockContentFfi
    var spans: [InlineTextFfi]
    var done: Bool
    var plainText: String { spans.map(\.content).joined() }
}

// ── Action repeater ───────────────────────────────────────────────────────────
// Repeats a closure at a fixed interval (key-repeat for navigation arrows).
// Encapsulates the Timer logic so the view model stays clean.

/// Fires a closure at a regular interval while a navigation key is held down.
final class ActionRepeater {
    private var timer: Timer?
    var active: Bool { timer != nil }

    /// Starts repeating `step` at `interval` seconds. A second call while active is a no-op.
    func start(interval: TimeInterval = 0.12, _ step: @escaping () -> Void) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in step() }
    }

    /// Stops the repeating timer.
    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// ── View Model ────────────────────────────────────────────────────────────────

/// Owns all document editing state: title, cover, blocks, undo/redo, and navigation.
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
    // Capacity aligned with CAPACITE_PAR_DEFAUT from the Rust backend (1000).
    let undoMgr = UndoManager()
    /// `canUndo` also reflects pending bursts: if the user triggers undo before the
    /// burst timer fires (`burstInterval`), `vm.undo()` flushes first, then undoes.
    var canUndo: Bool { undoMgr.canUndo || !blockBurstAnchor.isEmpty }
    var canRedo: Bool { undoMgr.canRedo }
    /// Snapshot of the last persisted title, used to compute the undo inverse.
    private var lastPersistedTitle: String = ""

    // ── Burst undo for typing ───────────────────────────────────────────
    // Notes-style: a continuous burst of saveBlock calls on the same block
    // counts as a single undo step. A `burstInterval` pause flushes the burst.
    struct BlockSnapshot: Equatable {
        let content: BlockContentFfi
        let spans: [InlineTextFfi]
        let done: Bool
    }
    /// Last known stable state per block (updated on each flush or non-burst mutation).
    /// Acts as the anchor for the next burst.
    private var blockSnapshots: [String: BlockSnapshot] = [:]
    /// Pre-burst state captured at the first saveBlock of a burst.
    /// This is what undo will restore.
    private var blockBurstAnchor: [String: BlockSnapshot] = [:]
    private var burstFlushWork: DispatchWorkItem?
    private var burstFlushBlockId: String?
    private let burstInterval: TimeInterval = 0.3

    private let api: PinkhaApi

    init(docId: String, api: PinkhaApi) {
        self.docId = docId
        self.api   = api
        undoMgr.levelsOfUndo = 1000
        // SwiftUI refreshes canUndo/canRedo via objectWillChange on each undo stack mutation.
        // We dispatch async to avoid publishing during a view update cycle (warning:
        // "Publishing changes from within view updates"), because NSUndoManagerCheckpoint
        // can be posted synchronously from any registerUndo call, including those triggered
        // by an onChange/binding inside body.
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

    /// Restores a block to a pre-burst anchor snapshot and re-registers the reverse
    /// as a redo action (UndoManager pattern: registerUndo during an undo registers redo).
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

    /// Writes the block to SQLite without touching burst tracking or blockSnapshots.
    /// Used by `saveBlock` (which manages the burst separately) and by `applyBlockSnapshot`.
    private func persistBlockRaw(_ block: EditableBlock) {
        do {
            let new = block.content.withSpans(block.spans, done: block.done)
            let data = try JSONEncoder().encode(new)
            try api.updateBlock(docId: docId, blockId: block.id,
                                 contentJson: String(data: data, encoding: .utf8)!)
        } catch { errorMessage = error.localizedDescription }
    }

    /// Persists a block for non-typing mutations (toggle, icon change, convert, etc.).
    /// Flushes any in-progress burst first so the structural change is not swallowed.
    func persistBlock(_ block: EditableBlock) {
        flushBurst(blockId: block.id)
        persistBlockRaw(block)
        blockSnapshots[block.id] = snapshotOf(block)
    }

    /// Flushes one burst: persists the final state and registers a single undo step
    /// that restores the pre-burst anchor. Called by the debounce timer, on block
    /// switch, or via `persistBlock` (structural mutation).
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
            // Initialize stable snapshots for burst undo tracking.
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
        let directory = base.appendingPathComponent("Pinkha/Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func imageExtension(_ ext: String) -> String {
        let cleaned = ext.lowercased()
        return ["jpg", "jpeg", "png", "heic", "webp"].contains(cleaned) ? cleaned : "jpg"
    }

    /// Called on every keystroke (RichTextEditor → save() → onSaveSpans).
    /// Only updates in-memory state and burst-undo tracking. SQLite persistence is
    /// deferred to `flushBurst` (at most 1 write per burst) to avoid saturating I/O.
    func saveBlock(_ block: EditableBlock) {
        let id = block.id
        // If the user switched to a different block, flush the previous burst (persists it).
        if let prevId = burstFlushBlockId, prevId != id {
            flushBurst(blockId: prevId)
        }
        // Start of burst: capture the pre-change state as the anchor.
        if blockBurstAnchor[id] == nil, let baseline = blockSnapshots[id] {
            blockBurstAnchor[id] = baseline
        }
        // The stable snapshot tracks the current (post-change) state.
        blockSnapshots[id] = snapshotOf(block)
        burstFlushBlockId = id
        // Debounce: no saveBlock for burstInterval → flush + persist.
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
            // Undo: delete the block we just created. deleteBlock auto-registers redo (re-insertion).
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
            // Undo: reinsert the block at its original position. reinsertBlock registers redo.
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.reinsertBlock(block, at: index)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Recreates a deleted block via the API (generates a new UUID) then reorders it
    /// back to its original position. The UUID changes across undo cycles but content
    /// is preserved — standard iOS undo behavior.
    /// Auto-focuses the restored block (cursor at end) — standard UX for undo of a deletion.
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
            // Redo: re-delete this block.
            undoMgr.registerUndo(withTarget: self) { vm in vm.deleteBlock(id: newId) }
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteBlocks(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids { flushBurst(blockId: id) }
        // Capture snapshots with their indices (ascending) for ordered restoration.
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

    /// Toggles the done state of a todo block. Undo toggles it again (self-re-registers).
    func toggleBlockDone(id: String) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[idx].done.toggle()
        persistBlock(blocks[idx])
        undoMgr.registerUndo(withTarget: self) { vm in vm.toggleBlockDone(id: id) }
    }

    /// Updates the emoji icon of a callout block. Undo restores the previous icon.
    func updateBlockIcon(id: String, icon: String) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        guard case .quote(let oldIcon, _) = blocks[idx].content, oldIcon != icon else { return }
        blocks[idx].content = .quote(icon: icon, text: blocks[idx].spans)
        persistBlock(blocks[idx])
        undoMgr.registerUndo(withTarget: self) { vm in
            vm.updateBlockIcon(id: id, icon: oldIcon)
        }
    }

    /// Converts block content (markdown shortcut: text → heading, etc.).
    /// Undo restores the previous content + spans; redo reapplies the conversion.
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

    /// Applies a block order (used by undo/redo of moveBlock).
    private func applyBlockOrder(_ order: [String]) {
        let oldOrder = blocks.map(\.id)
        let lookup = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        blocks = order.compactMap { lookup[$0] }
        try? api.reorderBlocks(docId: docId, order: order)
        undoMgr.registerUndo(withTarget: self) { vm in vm.applyBlockOrder(oldOrder) }
    }
}

// ── Block types ────────────────────────────────────────────────────────────────

/// All block types the user can insert via the block picker.
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

// ── Emoji persistence helpers ─────────────────────────────────────────────────

private let recentEmojisKey = "document.icon.recentEmojis"

/// Loads the list of recently used emoji icons from UserDefaults.
private func loadRecentEmojis() -> [String] {
    UserDefaults.standard.stringArray(forKey: recentEmojisKey) ?? []
}

/// Prepends `emoji` to the recents list (capped at 6), persists it, and returns the new list.
@discardableResult
private func saveRecentEmoji(_ emoji: String) -> [String] {
    let existing = UserDefaults.standard.stringArray(forKey: recentEmojisKey) ?? []
    let liste = Array(([emoji] + existing.filter { $0 != emoji }).prefix(6))
    UserDefaults.standard.set(liste, forKey: recentEmojisKey)
    return liste
}

// ── Document view ─────────────────────────────────────────────────────────────

/// Full-screen document editor: cover + icon header, title, blocks list, FAB, undo/redo pill.
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

    init(docId: String, api: PinkhaApi, onDisappear: (() -> Void)? = nil) {
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
                            onMerge: vm.blocks.first?.id == block.id ? nil : { spansToMerge in
                                guard let idx = vm.blocks.firstIndex(where: { $0.id == block.id }), idx > 0 else { return }
                                let prevIdx      = idx - 1
                                let prevId       = vm.blocks[prevIdx].id
                                let mergeOffset  = vm.blocks[prevIdx].spans.map(\.content).joined().count
                                vm.blocks[prevIdx].spans += spansToMerge
                                vm.saveBlock(vm.blocks[prevIdx])
                                vm.deleteBlock(id: block.id)
                                vm.autoFocusOffset = mergeOffset
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
                        deleteSelectedBlocks()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Supprimer les blocs sélectionnés")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let newLocked = !documentLocked
                    withAnimation(.easeInOut(duration: 0.15)) {
                        documentLocked = newLocked
                        if documentLocked {
                            editMode = .inactive
                            selectedBlocks.removeAll()
                            focusTitle = false
                            showingBlockPicker = false
                            vm.stopNavigationRepeat()
                        }
                    }
                    UserDefaults.standard.set(newLocked, forKey: lockKey)
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

        // Undo / redo pill at bottom-left, mirroring the FAB.
        // Single glass capsule background for both icons, matching the nav-bar lock/reorder style.
        if !documentLocked && editMode == .inactive && !keyboardVisible {
            UndoRedoPill(canUndo: vm.canUndo, canRedo: vm.canRedo,
                         onUndo: { vm.undo() }, onRedo: { vm.redo() })
                .padding(.leading, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.scale.combined(with: .opacity))
        }
        } // end ZStack
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

    private func deleteSelectedBlocks() {
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

// ── Cover + icon ──────────────────────────────────────────────────────────────

/// Renders the document cover image and emoji icon, plus the cover/icon action menus.
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

    // The inline menu shows recent emojis only (UIMenu does not scroll, so a fixed long list
    // would clip off screen). "All emojis" opens the full sheet with a grid + categories.

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
            Label(icone == nil ? "Ajouter une icône" : "Changer l'icône", systemImage: "face.smiling")
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
        if !recentEmojis.isEmpty {
            Divider()
            ForEach(recentEmojis.prefix(8), id: \.self) { emoji in
                Button(emoji) { onIcone(emoji) }
            }
        }
        if icone != nil {
            Divider()
            Button(role: .destructive) { onIcone(nil) } label: {
                Label("Retirer l'icône", systemImage: "trash")
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

    /// Loads a cover from the covers directory (filename) or from a file URL.
    private func coverImage(_ id: String) -> UIImage? {
        if !id.hasPrefix("file://") && !id.hasPrefix("cover.") {
            guard let directory = try? DocumentViewModel.coversDirectory() else { return nil }
            return UIImage(contentsOfFile: directory.appendingPathComponent(id).path)
        }
        guard let url = URL(string: id), url.isFileURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

/// Full-screen sheet for selecting or typing a document emoji icon.
private struct EmojiPickerSheet: View {
    let selection: String?
    let recents: [String]
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var inputOpen = false

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
                    if inputOpen {
                        customInput
                    }

                    if !recents.isEmpty {
                        emojiSection(name: "Récents", emojis: recents)
                    }

                    ForEach(categories, id: \.0) { nom, emojis in
                        emojiSection(name: nom, emojis: emojis)
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
                            inputOpen.toggle()
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

    private func validateInput() {
        guard let emoji = firstEmoji(input) else { return }
        onSelect(emoji)
        dismiss()
    }

    private var customInput: some View {
        HStack(spacing: 10) {
            TextField("Emoji", text: $input)
                .font(.system(size: 28))
                .textFieldStyle(.plain)
                .frame(height: 48)
                .padding(.horizontal, 14)
                .background(Color.secondary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .submitLabel(.done)
                .onSubmit { validateInput() }

            Button {
                validateInput()
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
            }
            .disabled(firstEmoji(input) == nil)
        }
    }

    private func emojiSection(name: String, emojis: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name)
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

    /// Returns the first emoji character in `text`, or `nil` if there is none.
    private func firstEmoji(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .first
            .map(String.init)
    }
}

// ── Document title ─────────────────────────────────────────────────────────────

/// SwiftUI wrapper that manages focus for the document title editor.
private struct DocumentTitleView: View {
    @Binding var title: String
    @Binding var focusDemande: Bool
    let onSave: () -> Void
    let onNewBlock: () -> Void
    @State private var focused = false

    var body: some View {
        TitleEditor(text: $title, isFocused: $focused,
                    onSave: onSave, onNewBlock: onNewBlock)
            .onChange(of: focusDemande) { _, requested in
                if requested {
                    focusDemande = false
                    DispatchQueue.main.async { focused = true }
                }
            }
    }
}

/// `UIViewRepresentable` wrapping an `ExpandingTextView` for the document title field.
/// Intercepts newline insertion to trigger block creation instead.
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
        tv.tintColor = pinkhaSelectionTint
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
        tv.tintColor = pinkhaSelectionTint
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
            // Clear placeholder text when editing starts.
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
            // Enter in the title: strip the newline and create the first block.
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

// ── Clickable empty state ─────────────────────────────────────────────────────

/// Placeholder editor shown when the document has no blocks yet. Tapping it creates the first block.
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
        .onChange(of: focused) { _, isFocused in
            if isFocused { onBegin() }
        }
    }
}

// ── Block editing callbacks ─────────────────────────────────────────────────────
// Groups the closures shared by all block types to avoid repeating them in each
// RowView and in BlockRowView.

/// Callback bundle passed from the document view to each block row.
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
    // Atomic mutations with undo: routed through the VM (toggleBlockDone, etc.)
    // so that the inverse is registered on the undo stack.
    var onToggleDone: (() -> Void)? = nil
    var onChangeIcon: ((String) -> Void)? = nil
    var onConvertContent: ((BlockContentFfi) -> Void)? = nil
    // Undo/redo exposed in the keyboard pill. Live closures — the Coordinator
    // calls them in textViewDidChange/textViewDidChangeSelection + updateUIView,
    // covering typing, undo, redo, and selection changes.
    var onUndo: (() -> Void)? = nil
    var onRedo: (() -> Void)? = nil
    var canUndoProvider: (() -> Bool)? = nil
    var canRedoProvider: (() -> Bool)? = nil
}

// ── Shared text editor for all blocks ─────────────────────────────────────────
// Single wiring of RichTextEditor + auto-focus + focus detection. Each RowView
// only provides the placeholder, font, decorations, and block-specific options.

/// Wraps `RichTextEditor` with auto-focus logic and focus change tracking.
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

// ── Block row dispatcher ───────────────────────────────────────────────────────

/// Routes each block to its dedicated row view based on content type.
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

// ── Text ──────────────────────────────────────────────────────────────────────

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

// ── Quote ─────────────────────────────────────────────────────────────────────

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
    @State private var emojiPickerOpen = false
    @State private var recentEmojis = loadRecentEmojis()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                emojiPickerOpen = true
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
        .sheet(isPresented: $emojiPickerOpen) {
            EmojiPickerSheet(selection: icon, recents: recentEmojis) { emoji in
                recentEmojis = saveRecentEmoji(emoji)
                // Route through the VM so the change is registered on the undo stack.
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

    /// Extra text attributes applied when the item is checked (strikethrough + secondary color).
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

// ── Add block button ──────────────────────────────────────────────────────────

/// Footer button that opens the block picker sheet.
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
// Single pill with two icons — visually identical to the lock/reorder pill in
// the nav bar: one glass capsule background, each icon independently tappable.

/// Glass-capsule pill showing undo and redo buttons. Shown at bottom-left when the keyboard is hidden.
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

// ── Block type picker sheet ───────────────────────────────────────────────────

/// Sheet listing all available block types for insertion.
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
