import SwiftUI

// ── View Model ────────────────────────────────────────────────────────────────

/// Owns all document editing state: title, cover, blocks, undo/redo and navigation.
/// The class is intentionally thin — feature-specific behaviour lives in
/// extensions (`+Blocks`, `+Persistence`, `+TitleCover`, `+Undo`) so each
/// concern is reviewable in isolation.
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
    /// Per-document accent color name (e.g. `"red"`). `nil` falls back
    /// to the global accent from `AppSettings`. Mirrors
    /// `Document.accent_color` from Rust; sync via `saveAccentColor`.
    @Published var accentColor: String? = nil
    /// Document-level writing direction (`"ltr"` / `"rtl"`). `nil`
    /// = system locale. Acts as the default for every block;
    /// `EditableBlock.textDirection` overrides per-block.
    @Published var textDirection: String? = nil
    /// Per-document Books-style theme name (raw value of
    /// `AppSettings.Theme`). `nil` inherits from the app-wide
    /// `settings.theme`. The editor renders the matching palette.
    @Published var theme: String? = nil
    /// User-overridable publish date in ISO-8601 (empty = "use
    /// `createdAt` as the effective publish date"). The DocumentMeta
    /// row carries the real value from SQLite; the toolbar lets the
    /// user move it back and forth on a calendar.
    @Published var publishedAt: String = ""
    /// Frozen creation date — surfaced in the toolbar's "Publish
    /// date" sheet as the implicit default and as the visual fallback
    /// when the user resets the override.
    @Published var createdAt: String = ""
    @Published var blocks: [EditableBlock] = []
    @Published var errorMessage: String?
    @Published var autoFocusId: String?
    @Published var autoFocusOffset: Int? = nil
    // @Published so DocumentView can observe focus changes and
    // scroll the freshly-focused block to a comfortable position
    // (well above the keyboard, not just barely clearing it).
    @Published var activeBlockId: String? = nil
    var focusedBlockId: String? = nil
    let repeater = ActionRepeater()
    var isNavigating: Bool { repeater.active }

    // ── Undo / redo ─────────────────────────────────────────────────────
    // The mechanism (burst typing, snapshot restore) lives in
    // `DocumentViewModel+Undo.swift`. Capacity is aligned with the Rust
    // backend's default (1000).
    let undoMgr = UndoManager()
    /// `canUndo` also reflects pending bursts: if the user triggers undo before the burst
    /// timer fires (`burstInterval`), `vm.undo()` flushes first, then undoes.
    var canUndo: Bool { undoMgr.canUndo || !blockBurstAnchor.isEmpty }
    var canRedo: Bool { undoMgr.canRedo }
    /// Snapshot of the last persisted title, used to compute the undo inverse.
    var lastPersistedTitle: String = ""

    // ── Burst state (owned here so the rest of the VM can read it) ─────
    /// Last known stable state per block (updated at each flush or
    /// non-burst mutation). Serves as the anchor for the next burst.
    var blockSnapshots: [String: BlockSnapshot] = [:]
    /// Pre-burst state captured at the first `saveBlock` of a burst.
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
}
