import SwiftUI
import PinkhaFFI
import PinkhaCore

// ── View Model ────────────────────────────────────────────────────────────────

/// Owns all leaf editing state: title, cover, blocks, undo/redo and navigation.
/// The class is intentionally thin — feature-specific behaviour lives in
/// extensions (`+Blocks`, `+Persistence`, `+TitleCover`, `+Undo`) so each
/// concern is reviewable in isolation.
@MainActor
@Observable
public final class LeafViewModel {
    let leafId: String
    var title: String = ""
    var cover: String?
    /// Page icon — emoji or filename in the covers directory. Mirrors
    /// `Leaf.icon` from Rust, sync via `saveIcon`.
    var icon: String?
    /// Read-only lock. Mirrors `Leaf.locked` from Rust. Imports default
    /// to `true`; the toolbar toggles via `saveLocked(_:)`.
    var locked: Bool = false
    /// Per-leaf accent color name (e.g. `"red"`). `nil` falls back
    /// to the global accent from `AppSettings`. Mirrors
    /// `Leaf.accent_color` from Rust; sync via `saveAccentColor`.
    var accentColor: String? = nil
    /// Leaf-level writing direction (`"ltr"` / `"rtl"`). `nil`
    /// = system locale. Acts as the default for every block;
    /// `EditableBlock.textDirection` overrides per-block.
    var textDirection: String? = nil
    /// Per-leaf Books-style theme name (raw value of
    /// `AppSettings.Theme`). `nil` inherits from the app-wide
    /// `settings.theme`. The editor renders the matching palette.
    var theme: String? = nil
    /// PRO-62 : per-leaf reader-settings bundle (font scale, font
    /// family, bold, line/letter/word spacing, margin, justify,
    /// dark variant, custom-layout flag). Mirrors the Rust
    /// `ReaderSettings` shape ; persisted via
    /// `api.updateLeafReaderSettings`. `nil` = theme defaults.
    var readerSettings: LeafReaderSettings = .init()
    /// User-overridable publish date in ISO-8601 (empty = "use
    /// `createdAt` as the effective publish date"). The LeafMeta
    /// row carries the real value from SQLite; the toolbar lets the
    /// user move it back and forth on a calendar.
    var publishedAt: String = ""
    /// Frozen creation date — surfaced in the toolbar's "Publish
    /// date" sheet as the implicit default and as the visual fallback
    /// when the user resets the override.
    var createdAt: String = ""
    var blocks: [EditableBlock] = []
    var errorMessage: String?
    var autoFocusId: String?
    var autoFocusOffset: Int? = nil
    // Observed so LeafView re-renders on focus changes and scrolls
    // the freshly-focused block to a comfortable position above the keyboard.
    var activeBlockId: String? = nil
    @ObservationIgnored var focusedBlockId: String? = nil
    @ObservationIgnored let repeater = ActionRepeater()
    var isNavigating: Bool { repeater.active }

    // ── Undo / redo ─────────────────────────────────────────────────────
    // The mechanism (burst typing, snapshot restore) lives in
    // `LeafViewModel+Undo.swift`. Capacity is aligned with the Rust
    // backend's default (1000).
    @ObservationIgnored let undoMgr = UndoManager()
    /// Bumped on every `NSUndoManagerCheckpoint` so the observation
    /// runtime re-evaluates `canUndo` / `canRedo` (which read the
    /// non-observable `UndoManager`). Without this tick the toolbar's
    /// undo/redo buttons would never refresh — `@Observable` only
    /// tracks reads of its own stored properties.
    private var undoTick: Int = 0
    /// Dernières valeurs publiées, pour n'incrémenter `undoTick` QUE
    /// lorsqu'elles changent. `@ObservationIgnored` : les lire ne doit
    /// créer aucune dépendance, sinon on rouvre le cycle qu'on ferme ici.
    @ObservationIgnored private var lastPublishedCanUndo = false
    @ObservationIgnored private var lastPublishedCanRedo = false

    /// Incrémente le tick d'observation seulement si `canUndo` / `canRedo`
    /// ont réellement changé.
    ///
    /// Sans ce garde, l'app brûle un coeur entier en permanence dès qu'une
    /// leaf est ouverte, sans aucune interaction. Le cycle :
    ///
    ///   `UndoManager` émet un checkpoint à CHAQUE tour de boucle
    ///   d'exécution (il ouvre un groupe par événement)
    ///     → on incrémente `undoTick`, propriété observée
    ///     → `canUndo` la lit, donc `UndoRedoPill` est invalidée
    ///     → SwiftUI refait une passe de rendu
    ///     → la boucle d'exécution tourne, un nouveau checkpoint part
    ///
    /// Le saut `Task { @MainActor }` — ajouté pour éviter l'avertissement
    /// « Publishing changes from within view updates » — ne supprime pas
    /// l'écriture, il la reporte d'un tour. Le cycle se referme quand même,
    /// à 60 Hz.
    ///
    /// Mesuré : 100 % de CPU au repos dans une leaf, pile de mise en page de
    /// 5274 niveaux, ~340 objets autoreleased par seconde. Alimenter la
    /// pastille avec des constantes faisait tomber à 0,7 % — c'est ce qui a
    /// désigné cette écriture. La chauffe de l'appareil, les saccades et le
    /// gel au changement d'onglet venaient tous de là.
    func bumpUndoTickIfNeeded() {
        let u = undoMgr.canUndo || !blockBurstAnchor.isEmpty
        let r = undoMgr.canRedo
        guard u != lastPublishedCanUndo || r != lastPublishedCanRedo else { return }
        lastPublishedCanUndo = u
        lastPublishedCanRedo = r
        // Le report d'un tour ne sert qu'ICI : un checkpoint peut partir
        // synchronement depuis un `registerUndo` invoqué pendant une passe de
        // rendu, et muter un état observé à ce moment-là déclenche
        // « Publishing changes from within view updates ». On ne paie ce saut
        // que lorsqu'il y a vraiment quelque chose à publier — donc quelques
        // fois par session, pas soixante fois par seconde.
        Task { @MainActor [weak self] in
            self?.undoTick &+= 1
        }
    }
    /// `canUndo` also reflects pending bursts: if the user triggers undo before the burst
    /// timer fires (`burstInterval`), `vm.undo()` flushes first, then undoes.
    var canUndo: Bool {
        _ = undoTick
        return undoMgr.canUndo || !blockBurstAnchor.isEmpty
    }
    var canRedo: Bool {
        _ = undoTick
        return undoMgr.canRedo
    }
    /// Snapshot of the last persisted title, used to compute the undo inverse.
    @ObservationIgnored var lastPersistedTitle: String = ""

    // ── Burst state (owned here so the rest of the VM can read it) ─────
    /// Last known stable state per block (updated at each flush or
    /// non-burst mutation). Serves as the anchor for the next burst.
    @ObservationIgnored var blockSnapshots: [String: BlockSnapshot] = [:]
    /// Pre-burst state captured at the first `saveBlock` of a burst.
    /// This is what undo will restore.
    @ObservationIgnored var blockBurstAnchor: [String: BlockSnapshot] = [:]
    /// Pending burst-flush task. Cancelled when a new keystroke arrives or
    /// when the user switches blocks ; awaited by `flushAllBursts` so a
    /// `load()` after a typing burst always sees the latest persisted
    /// state.
    @ObservationIgnored var burstFlushTask: Task<Void, Never>?
    @ObservationIgnored var burstFlushBlockId: String?
    @ObservationIgnored let burstInterval: Duration = .milliseconds(300)

    @ObservationIgnored let api: PinkhaApi

    /// Token for the checkpoint observer below — kept so `deinit` can
    /// unregister instead of leaving a dead block in the center's table.
    /// `nonisolated(unsafe)` because a nonisolated `deinit` can't touch
    /// MainActor state under Swift 6 ; the token is written once in `init`
    /// and read once in `deinit`, and `removeObserver` is thread-safe.
    @ObservationIgnored nonisolated(unsafe) private var undoCheckpointObserver: (any NSObjectProtocol)?

    public init(leafId: String, api: PinkhaApi) {
        self.leafId = leafId
        self.api   = api
        undoMgr.levelsOfUndo = 1000
        // Bump the observable tick on every undo-stack mutation so SwiftUI
        // re-reads the `canUndo` / `canRedo` computed properties on the next
        // body eval. The `Task { @MainActor }` hop defers the mutation past
        // the current view update — `NSUndoManagerCheckpoint` can fire
        // synchronously from a registerUndo invoked inside a view update.
        // (A `NotificationCenter.notifications(named:)` async sequence would
        // be the fully-structured form, but untyped `Notification` isn't
        // Sendable under Swift 6 and the iOS 26 typed-message API doesn't
        // cover UndoManager's checkpoint — the block observer stays.)
        undoCheckpointObserver = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerCheckpoint,
            object: undoMgr,
            queue: .main
        ) { [weak self] _ in
            // Le bloc est déjà livré sur la file principale (`queue: .main`),
            // donc on peut lire l'état synchronement. C'est ESSENTIEL : créer
            // un `Task` ici, même vide, réveille la boucle d'exécution, et une
            // boucle réveillée fait émettre à `UndoManager` un nouveau
            // checkpoint. La tâche était elle-même la pompe.
            MainActor.assumeIsolated {
                self?.bumpUndoTickIfNeeded()
            }
        }
    }

    deinit {
        if let undoCheckpointObserver {
            NotificationCenter.default.removeObserver(undoCheckpointObserver)
        }
    }
}
