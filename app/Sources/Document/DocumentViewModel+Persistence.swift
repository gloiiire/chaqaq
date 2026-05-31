import SwiftUI

// ── Persistance ───────────────────────────────────────────────────────────────

extension DocumentViewModel {

    /// Écrit le bloc dans SQLite sans toucher au burst tracking ni aux blockSnapshots.
    /// Utilisé par `saveBlock` (qui gère le burst séparément) et par `applyBlockSnapshot`.
    func persistBlockRaw(_ block: EditableBlock) {
        do {
            let new = block.content.withSpans(block.spans, done: block.done)
            let data = try JSONEncoder().encode(new)
            try api.updateBlock(docId: docId, blockId: block.id,
                                 contentJson: String(decoding: data, as: UTF8.self))
        } catch { errorMessage = error.localizedDescription }
    }

    /// Persiste un bloc pour les mutations non-frappe (toggle, changement d'icône, conversion, etc.).
    /// Flush d'abord tout burst en cours pour que le changement structurel ne soit pas englouti.
    func persistBlock(_ block: EditableBlock) {
        flushBurst(blockId: block.id)
        persistBlockRaw(block)
        blockSnapshots[block.id] = snapshotOf(block)
    }

    /// Flush un burst : persiste l'état final et enregistre une seule étape undo
    /// qui restaure l'ancre pré-burst. Appelé par le timer debounce, au changement de bloc,
    /// ou via `persistBlock` (mutation structurelle).
    func flushBurst(blockId: String) {
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

    func flushAllBursts() {
        burstFlushWork?.cancel()
        burstFlushWork = nil
        for id in Array(blockBurstAnchor.keys) { flushBurst(blockId: id) }
        burstFlushBlockId = nil
    }

    /// Appelé à chaque frappe (RichTextEditor → save() → onSaveSpans).
    /// Met à jour uniquement l'état en mémoire et le burst-undo tracking. La persistance SQLite
    /// est différée à `flushBurst` (au plus 1 write par burst) pour éviter de saturer les I/O.
    func saveBlock(_ block: EditableBlock) {
        let id = block.id
        // Si l'utilisateur change de bloc, flush le burst précédent (le persiste).
        if let prevId = burstFlushBlockId, prevId != id {
            flushBurst(blockId: prevId)
        }
        // Début de burst : capture l'état pré-changement comme ancre.
        if blockBurstAnchor[id] == nil, let baseline = blockSnapshots[id] {
            blockBurstAnchor[id] = baseline
        }
        // Le snapshot stable suit l'état courant (post-changement).
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

    func load() {
        // Flush les bursts en attente avant de recharger depuis SQLite,
        // sinon load() écraserait l'état in-memory non encore persisté.
        flushAllBursts()
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
            // Initialise les snapshots stables pour le burst undo tracking.
            blockSnapshots = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, snapshotOf($0)) })
            blockBurstAnchor.removeAll()
        } catch { errorMessage = error.localizedDescription }
    }
}
