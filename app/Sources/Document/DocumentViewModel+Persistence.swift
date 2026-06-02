import SwiftUI

// ── Persistence ───────────────────────────────────────────────────────────────

extension DocumentViewModel {

    /// Writes the block to SQLite without touching burst tracking or blockSnapshots.
    /// Used by `saveBlock` (which manages the burst separately) and by `applyBlockSnapshot`.
    func persistBlockRaw(_ block: EditableBlock) {
        do {
            let new = block.content.withSpans(block.spans, done: block.done)
            let data = try JSONEncoder().encode(new)
            try api.updateBlock(docId: docId, blockId: block.id,
                                 contentJson: String(decoding: data, as: UTF8.self))
        } catch { errorMessage = error.localizedDescription }
    }

    /// Persists a block for non-typing mutations (toggle, icon change, conversion, etc.).
    /// Flushes any ongoing burst first so the structural change is not swallowed.
    func persistBlock(_ block: EditableBlock) {
        flushBurst(blockId: block.id)
        persistBlockRaw(block)
        blockSnapshots[block.id] = snapshotOf(block)
    }

    /// Flushes a burst: persists the final state and registers a single undo step
    /// that restores the pre-burst anchor. Called by the debounce timer, on block change,
    /// or via `persistBlock` (structural mutation).
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

    /// Called on every keystroke (RichTextEditor → save() → onSaveSpans).
    /// Only updates in-memory state and burst-undo tracking. SQLite persistence
    /// is deferred to `flushBurst` (at most 1 write per burst) to avoid saturating I/O.
    func saveBlock(_ block: EditableBlock) {
        let id = block.id
        // If the user switches blocks, flush the previous burst (persists it).
        if let prevId = burstFlushBlockId, prevId != id {
            flushBurst(blockId: prevId)
        }
        // Start of burst: capture the pre-change state as anchor.
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

    func load() {
        // Flush pending bursts before reloading from SQLite,
        // otherwise load() would overwrite in-memory state not yet persisted.
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
                              done:  $0.content.isTodoDone,
                              color: $0.color)
            }
            // Initialise stable snapshots for burst undo tracking.
            blockSnapshots = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, snapshotOf($0)) })
            blockBurstAnchor.removeAll()
        } catch { errorMessage = error.localizedDescription }
    }
}
