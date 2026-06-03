import SwiftUI

// ── View Model ────────────────────────────────────────────────────────────────

/// Owns all document editing state: title, cover, blocks, undo/redo and navigation.
@MainActor
final class DocumentViewModel: ObservableObject {
    let docId: String
    @Published var title: String = ""
    @Published var cover: String?
    /// Page icon — emoji or filename in the covers directory. Mirrors
    /// `Document.icon` from Rust, sync via `saveIcon`.
    @Published var icon: String?
    /// Read-only lock. Mirrors `Document.locked` from Rust. Imports default
    /// to `true`; the toolbar toggles via `saveLocked(_:)`.
    @Published var locked: Bool = false
    @Published var blocks: [EditableBlock] = []
    @Published var errorMessage: String?
    @Published var autoFocusId: String?
    @Published var autoFocusOffset: Int? = nil
    var activeBlockId: String? = nil
    var focusedBlockId: String? = nil
    let repeater = ActionRepeater()
    var isNavigating: Bool { repeater.active }

    // ── Undo / redo ─────────────────────────────────────────────────────
    // Capacity aligned with the Rust backend's default (1000).
    let undoMgr = UndoManager()
    /// `canUndo` also reflects pending bursts: if the user triggers undo before the burst
    /// timer fires (`burstInterval`), `vm.undo()` flushes first, then undoes.
    var canUndo: Bool { undoMgr.canUndo || !blockBurstAnchor.isEmpty }
    var canRedo: Bool { undoMgr.canRedo }
    /// Snapshot of the last persisted title, used to compute the undo inverse.
    var lastPersistedTitle: String = ""

    // ── Burst undo for typing ────────────────────────────────────────────
    // Notes style: a continuous burst of saveBlock calls on the same block
    // counts as a single undo step. A `burstInterval` pause flushes the burst.
    struct BlockSnapshot: Equatable {
        let content: BlockContentFfi
        let spans: [InlineTextFfi]
        let done: Bool
    }
    /// Last known stable state per block (updated at each flush or non-burst mutation).
    /// Serves as anchor for the next burst.
    var blockSnapshots: [String: BlockSnapshot] = [:]
    /// Pre-burst state captured at the first saveBlock of a burst.
    /// This is what undo will restore.
    var blockBurstAnchor: [String: BlockSnapshot] = [:]
    var burstFlushWork: DispatchWorkItem?
    var burstFlushBlockId: String?
    let burstInterval: TimeInterval = 0.3

    let api: PinkhaApi

    init(docId: String, api: PinkhaApi) {
        self.docId = docId
        self.api   = api
        undoMgr.levelsOfUndo = 1000
        // SwiftUI refreshes canUndo/canRedo via objectWillChange on every mutation of the undo stack.
        // We dispatch async to avoid publishing during a view update cycle (warning:
        // "Publishing changes from within view updates"), because NSUndoManagerCheckpoint can be posted
        // synchronously from any registerUndo call, including those triggered
        // by an onChange/binding in body.
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

    func snapshotOf(_ block: EditableBlock) -> BlockSnapshot {
        BlockSnapshot(content: block.content, spans: block.spans, done: block.done)
    }

    /// Restores a block to a pre-burst anchor snapshot and re-registers the inverse
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
}
