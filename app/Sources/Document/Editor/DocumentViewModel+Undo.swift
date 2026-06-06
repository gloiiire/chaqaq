import SwiftUI

// ── Undo / redo + Notes-style burst typing ──────────────────────────────────

/// Notes-style burst undo: a continuous run of `saveBlock` calls on the same
/// block coalesces into a single undo step. A `burstInterval` pause flushes
/// the burst, which is the moment we register the inverse with `undoMgr` and
/// persist to SQLite (so we get exactly one write per burst, not per
/// keystroke).
extension DocumentViewModel {
    /// Snapshot used by the burst engine to remember a block's state at the
    /// start of a burst (the "anchor") and at each flushed checkpoint.
    struct BlockSnapshot: Equatable {
        let content: BlockContentFfi
        let spans: [InlineTextFfi]
        let done: Bool
    }

    func undo() { flushAllBursts(); undoMgr.undo() }
    func redo() { flushAllBursts(); undoMgr.redo() }

    func snapshotOf(_ block: EditableBlock) -> BlockSnapshot {
        BlockSnapshot(content: block.content, spans: block.spans, done: block.done)
    }

    /// Restores a block to a pre-burst anchor snapshot and re-registers the
    /// inverse as a redo action (UndoManager pattern: a `registerUndo` call
    /// made during an undo registers the redo).
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
}
