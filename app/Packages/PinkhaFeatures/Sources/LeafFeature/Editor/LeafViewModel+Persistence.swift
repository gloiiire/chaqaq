import SwiftUI
import PinkhaFFI
import PinkhaRichText

// ── Persistence ───────────────────────────────────────────────────────────────

public extension LeafViewModel {

    /// Writes the block to SQLite without touching burst tracking or blockSnapshots.
    /// Used by `saveBlock` (which manages the burst separately) and by `applyBlockSnapshot`.
    func persistBlockRaw(_ block: EditableBlock) {
        do {
            let new = block.content.withSpans(block.spans, done: block.done)
            let data = try JSONEncoder().encode(new)
            try api.updateBlock(leafId: leafId, blockId: block.id,
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
    /// that restores the pre-burst anchor. Called by the debounce task,
    /// on block change, or via `persistBlock` (structural mutation).
    func flushBurst(blockId: String) {
        guard let anchor = blockBurstAnchor[blockId] else { return }
        let current = blockSnapshots[blockId]
        blockBurstAnchor.removeValue(forKey: blockId)
        if burstFlushBlockId == blockId {
            burstFlushBlockId = nil
            burstFlushTask?.cancel()
            burstFlushTask = nil
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
        burstFlushTask?.cancel()
        burstFlushTask = nil
        for id in Array(blockBurstAnchor.keys) { flushBurst(blockId: id) }
        burstFlushBlockId = nil
    }

    /// Called on every keystroke (RichTextEditor → save() → onSaveSpans).
    /// Only updates in-memory state and burst-undo tracking. SQLite persistence
    /// is deferred to `flushBurst` (at most 1 write per burst) to avoid saturating I/O.
    func saveBlock(_ block: EditableBlock) {
        let id = block.id
        // Sync the in-memory array with the passed value. UI callers mutate
        // `blocks` in place through the two-way binding (no-op here), but a
        // caller holding a copy would otherwise see its change silently
        // dropped at flush time — `flushBurst` persists from `blocks`.
        if let idx = blocks.firstIndex(where: { $0.id == id }), blocks[idx] != block {
            blocks[idx] = block
        }
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
        // Debounce: no saveBlock for `burstInterval` → flush + persist. The
        // task inherits the VM's MainActor isolation, so `flushBurst` runs
        // on the main actor without an explicit hop.
        burstFlushTask?.cancel()
        burstFlushTask = Task { [weak self, burstInterval] in
            try? await Task.sleep(for: burstInterval)
            guard !Task.isCancelled, let self else { return }
            self.flushBurst(blockId: id)
        }
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
            let doc = try api.getLeaf(id: leafId)
            title = doc.title.map(\.content).joined()
            lastPersistedTitle = title
            cover = doc.cover
            icon = doc.icon
            locked = doc.locked ?? false
            accentColor = doc.accentColor
            textDirection = doc.textDirection
            theme = doc.theme
            readerSettings = doc.readerSettings ?? .init()
            blocks = LeafViewModel.flattenBlocks(doc.blocks, depth: 0)
            // Initialise stable snapshots for burst undo tracking.
            blockSnapshots = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, snapshotOf($0)) })
            blockBurstAnchor.removeAll()
            // `published_at` / `created_at` live on the meta row, not in the
            // leaf JSON, so the toolbar's "Publish date" sheet needs them
            // fetched separately.
            //
            // One indexed row lookup, not `listLeaves().first(where:)` —
            // that walked the *entire* library and marshalled a
            // `LeafMetaFfi` for every leaf across the FFI, just to read two
            // strings. On an imported library that was thousands of structs
            // per leaf open, delaying the push animation.
            if let meta = try? api.getLeafMeta(id: leafId) {
                createdAt = meta.createdAt
                publishedAt = meta.publishedAt
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Persists a new publish date (ISO-8601) for this leaf and
    /// registers an undo step. Empty string = reset to `created_at`
    /// (the Rust use case treats empty as "follow created_at").
    func savePublishedAt(_ newValue: String) {
        let previous = publishedAt
        guard previous != newValue else { return }
        publishedAt = newValue
        do {
            try api.updateLeafPublishedAt(id: leafId, newPublishedAt: newValue)
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.savePublishedAt(previous)
            }
        } catch {
            errorMessage = error.localizedDescription
            publishedAt = previous
        }
    }

    /// Depth-first flatten of the recursive `BlockFfi` tree into the flat list
    /// the editor UI renders. Each child is appended right after its parent
    /// with `depth + 1`, so the visual order matches the leaf's reading
    /// order and indent levels translate to a left-padding in the view.
    static func flattenBlocks(_ tree: [BlockFfi], depth: Int) -> [EditableBlock] {
        var result: [EditableBlock] = []
        result.reserveCapacity(tree.count)
        for node in tree {
            result.append(EditableBlock(
                id: node.id,
                content: node.content,
                spans: node.content.spansOrEmpty,
                done: node.content.isTodoDone,
                color: node.color,
                backgroundColor: node.backgroundColor,
                textDirection: node.textDirection,
                depth: depth
            ))
            if !node.children.isEmpty {
                result.append(contentsOf: flattenBlocks(node.children, depth: depth + 1))
            }
        }
        return result
    }
}
