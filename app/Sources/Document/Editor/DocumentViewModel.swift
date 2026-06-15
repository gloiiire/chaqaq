import SwiftUI
import PinkhaFFI

// ── View Model ────────────────────────────────────────────────────────────────

/// Owns all document editing state: title, cover, blocks, undo/redo and navigation.
/// The class is intentionally thin — feature-specific behaviour lives in
/// extensions (`+Blocks`, `+Persistence`, `+TitleCover`, `+Undo`) so each
/// concern is reviewable in isolation.
@MainActor
@Observable
final class DocumentViewModel {
    let docId: String
    var title: String = ""
    var cover: String?
    /// Page icon — emoji or filename in the covers directory. Mirrors
    /// `Document.icon` from Rust, sync via `saveIcon`.
    var icon: String?
    /// Read-only lock. Mirrors `Document.locked` from Rust. Imports default
    /// to `true`; the toolbar toggles via `saveLocked(_:)`.
    var locked: Bool = false
    /// Per-document accent color name (e.g. `"red"`). `nil` falls back
    /// to the global accent from `AppSettings`. Mirrors
    /// `Document.accent_color` from Rust; sync via `saveAccentColor`.
    var accentColor: String? = nil
    /// Document-level writing direction (`"ltr"` / `"rtl"`). `nil`
    /// = system locale. Acts as the default for every block;
    /// `EditableBlock.textDirection` overrides per-block.
    var textDirection: String? = nil
    /// Per-document Books-style theme name (raw value of
    /// `AppSettings.Theme`). `nil` inherits from the app-wide
    /// `settings.theme`. The editor renders the matching palette.
    var theme: String? = nil
    /// User-overridable publish date in ISO-8601 (empty = "use
    /// `createdAt` as the effective publish date"). The DocumentMeta
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
    // Observed so DocumentView re-renders on focus changes and scrolls
    // the freshly-focused block to a comfortable position above the keyboard.
    var activeBlockId: String? = nil
    @ObservationIgnored var focusedBlockId: String? = nil
    @ObservationIgnored let repeater = ActionRepeater()
    var isNavigating: Bool { repeater.active }

    // ── Undo / redo ─────────────────────────────────────────────────────
    // The mechanism (burst typing, snapshot restore) lives in
    // `DocumentViewModel+Undo.swift`. Capacity is aligned with the Rust
    // backend's default (1000).
    @ObservationIgnored let undoMgr = UndoManager()
    /// Bumped on every `NSUndoManagerCheckpoint` so the observation
    /// runtime re-evaluates `canUndo` / `canRedo` (which read the
    /// non-observable `UndoManager`). Without this tick the toolbar's
    /// undo/redo buttons would never refresh — `@Observable` only
    /// tracks reads of its own stored properties.
    private var undoTick: Int = 0
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

    init(docId: String, api: PinkhaApi) {
        self.docId = docId
        self.api   = api
        undoMgr.levelsOfUndo = 1000
        // Bump the observable tick on every undo-stack mutation so SwiftUI
        // re-reads the `canUndo` / `canRedo` computed properties on the next
        // body eval. Dispatched async to dodge "Publishing changes from
        // within view updates" — `NSUndoManagerCheckpoint` can fire
        // synchronously from a registerUndo invoked inside a view update.
        NotificationCenter.default.addObserver(
            forName: .NSUndoManagerCheckpoint,
            object: undoMgr,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.undoTick &+= 1
            }
        }
    }
}
