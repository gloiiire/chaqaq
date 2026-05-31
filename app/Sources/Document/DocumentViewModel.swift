import SwiftUI

// ── View Model ────────────────────────────────────────────────────────────────

/// Possède tout l'état d'édition du document : titre, couverture, blocs, undo/redo et navigation.
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
    var focusedBlockId: String? = nil
    let repeater = ActionRepeater()
    var isNavigating: Bool { repeater.active }

    // ── Undo / redo ─────────────────────────────────────────────────────
    // Capacité alignée sur CAPACITE_PAR_DEFAUT du backend Rust (1000).
    let undoMgr = UndoManager()
    /// `canUndo` reflète aussi les bursts en attente : si l'utilisateur déclenche undo avant que
    /// le timer de burst ne se déclenche (`burstInterval`), `vm.undo()` flush d'abord, puis annule.
    var canUndo: Bool { undoMgr.canUndo || !blockBurstAnchor.isEmpty }
    var canRedo: Bool { undoMgr.canRedo }
    /// Snapshot du dernier titre persisté, utilisé pour calculer l'inverse undo.
    var lastPersistedTitle: String = ""

    // ── Burst undo pour la frappe ───────────────────────────────────────
    // Style Notes : une rafale continue d'appels saveBlock sur le même bloc
    // compte comme une seule étape undo. Une pause `burstInterval` flush le burst.
    struct BlockSnapshot: Equatable {
        let content: BlockContentFfi
        let spans: [InlineTextFfi]
        let done: Bool
    }
    /// Dernier état stable connu par bloc (mis à jour à chaque flush ou mutation non-burst).
    /// Sert d'ancre pour le prochain burst.
    var blockSnapshots: [String: BlockSnapshot] = [:]
    /// État pré-burst capturé au premier saveBlock d'un burst.
    /// C'est ce que undo va restaurer.
    var blockBurstAnchor: [String: BlockSnapshot] = [:]
    var burstFlushWork: DispatchWorkItem?
    var burstFlushBlockId: String?
    let burstInterval: TimeInterval = 0.3

    let api: PinkhaApi

    init(docId: String, api: PinkhaApi) {
        self.docId = docId
        self.api   = api
        undoMgr.levelsOfUndo = 1000
        // SwiftUI rafraîchit canUndo/canRedo via objectWillChange à chaque mutation de la pile undo.
        // On dispatch async pour éviter de publier pendant un cycle de mise à jour de vue (warning :
        // "Publishing changes from within view updates"), car NSUndoManagerCheckpoint peut être posté
        // de manière synchrone depuis tout appel registerUndo, y compris ceux déclenchés
        // par un onChange/binding dans body.
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

    /// Restaure un bloc à un snapshot d'ancre pré-burst et re-enregistre l'inverse
    /// comme action redo (pattern UndoManager : registerUndo pendant un undo enregistre redo).
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
