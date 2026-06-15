import SwiftUI

// ── Composer state ────────────────────────────────────────────────────────────

/// Owns the presentation state for the global create bubble — sheets,
/// alerts and the create mode picker. Lives at the `ContentView` level so
/// the bubble inside `tabViewBottomAccessory` can drive create / trash /
/// import flows regardless of which tab is currently selected.
@MainActor
@Observable
final class Composer {
    /// Whether the leaf/book title prompt is on screen.
    var showingCreateDoc = false
    /// Whether the new-shelf alert is on screen.
    var showingNewShelf = false
    /// Whether the trash sheet is on screen.
    var showingTrash = false
    /// Whether the Safari-tab-style "All leaves" full-screen
    /// switcher is on screen — opened from the overflow menu in the
    /// bottom accessory.
    var showingAllDocs = false
    /// Whether the Notion import sheet is on screen.
    var showingNotionImport = false
    /// Whether the Bear import sheet is on screen.
    var showingBearImport = false
    /// Whether the Craft TextBundle import sheet is on screen.
    var showingCraftTextBundleImport = false
    /// Whether the Craft combined import sheet is on screen.
    var showingCraftCombinedImport = false
    /// First-step Delete All confirmation alert.
    var showingDeleteAllConfirm = false
    /// Second-step Delete All confirmation alert.
    var showingDeleteAllConfirm2 = false
    /// Title draft for the create leaf sheet.
    var newTitle = ""
    /// Name draft for the new-shelf alert.
    var newShelfName = ""
    /// Which kind of leaf the create sheet should produce.
    var createMode: CreateMode = .note
    /// Where the next `New …` should land. Driven by the navigation
    /// stack — `ShelfView` flips it to `.shelf(id)` on appear (and
    /// back to `.root` on disappear), `LeafView` flips it to
    /// `.leaf(id)`. The home, books and inbox screens leave the
    /// default `.root`, so anything created from there lands at the
    /// top of the library.
    var currentContext: CreationContext = .root
    /// Signals that a child page has just been created from inside a
    /// leaf and needs to be embedded as a `Page` block in the active
    /// editor. The LeafView observes this and routes the insertion
    /// through its VM — otherwise the next burst flush would overwrite
    /// a block written behind the VM's back via a direct FFI call.
    var pendingChildPage: PendingChildPage? = nil
    /// Signals that a newly-created note should be pushed onto the
    /// Notes navigation stack right after the create sheet dismisses,
    /// so the user lands in the editor instead of back on the home
    /// list. Only set for `.root` / `.shelf` contexts — the
    /// `.leaf` context routes through `pendingChildPage` instead.
    var pendingOpenDoc: String? = nil

    /// NotificationCenter signal — when the switcher dismisses with
    /// zero open tabs, posts this so the active `NavigationStack`
    /// pops to root. Going through `NotificationCenter` instead of an
    /// observation-driven counter sidesteps the SwiftUI binding
    /// propagation quirks we hit (`.onChange` not firing reliably
    /// while a fullScreenCover is dismissing).
    static let popHomeNotification = Notification.Name("pinkha.popHomeRequest")

    /// Posted by the LeafView breadcrumb when the user taps an
    /// ancestor segment. `userInfo["leafId"]` carries the target —
    /// LibraryView truncates its NavigationStack `path` to keep
    /// only entries up to and including that doc.
    static let popToDocNotification = Notification.Name("pinkha.popToDoc")

    /// Posted whenever a leaf's title is persisted (FFI write
    /// succeeded). `userInfo["leafId"]` carries the doc that changed.
    /// Used by every mounted LeafView to refresh its
    /// `docMetaById` cache — otherwise a child's breadcrumb keeps
    /// showing the old parent title until the user pops to root.
    static let docTitleChangedNotification = Notification.Name("pinkha.docTitleChanged")

    /// Currently-selected pinkha tab. Bound to the root `TabView`
    /// `selection:` so we can programmatically switch tabs from
    /// anywhere (e.g. the switcher's ✓ button forcing a return to
    /// Notes after closing all open docs).
    var selectedTab: TabKind = .notes

    // NavigationStack path lives back in `LibraryView.@State` because
    // `NavigationStack(path: $model.path)` is buggy in iOS — it doesn't
    // visibly pop when the binding is mutated, while `@State` does.

    /// Bump this to force-recreate `LibraryView` via `.id(notesHomeKey)`.
    /// Used by the switcher's ✓ button to nuke a stuck NavStack
    /// (Apple SwiftUI bug : path mutation from outside doesn't always
    /// visibly pop even when the binding fires). Recreating the view
    /// instantiates fresh `@State` → path starts at `[]` → home shown.
    var notesHomeKey: Int = 0

    /// The four pinkha tabs. `rawValue` is stable for `Codable` use if
    /// we ever persist the last-selected tab; the enum itself is
    /// `Hashable` so it works as a `TabView` selection binding.
    enum TabKind: String, Hashable, Codable {
        case notes, books, inbox, search
    }

    enum CreateMode { case note, book }

    /// Anchor for context-aware creation — the bubble inherits the
    /// "where am I?" from the foreground view so a new note created
    /// while looking at shelf "K" lands inside "K", not at root.
    enum CreationContext: Equatable {
        case root
        case shelf(id: String)
        case leaf(id: String)
    }

    /// Payload of `pendingChildPage`. The parent doc id lets the active
    /// `LeafView` filter — only the editor showing `parentLeafId`
    /// should react and consume the signal.
    struct PendingChildPage: Equatable {
        let parentLeafId: String
        let childLeafId: String
    }

    func openNewNote() {
        createMode = .note
        newTitle = ""
        showingCreateDoc = true
    }

    /// Wires Home Screen Quick Actions (long-press the app icon) into
    /// the composer. Call once on app start — covers both the cold
    /// launch path (a shortcut tap that woke the app from suspended,
    /// captured by `AppDelegate.pendingShortcutType`) and the warm
    /// launch path (Scene-delegate notification while the app is
    /// already in memory).
    func bindQuickActions() {
        // Drain any shortcut captured during cold launch.
        if let type = AppDelegate.pendingShortcutType {
            AppDelegate.pendingShortcutType = nil
            handle(shortcutType: type)
        }
        NotificationCenter.default.addObserver(
            forName: .pinkhaQuickAction,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let type = note.userInfo?["type"] as? String else { return }
            Task { @MainActor in self?.handle(shortcutType: type) }
        }
    }

    private func handle(shortcutType type: String) {
        switch type {
        case "com.gloiiire.pinkha.new-note":
            openNewNote()
        default:
            break
        }
    }

    func openNewBook() {
        createMode = .book
        newTitle = ""
        showingCreateDoc = true
    }

    func openNewShelf() {
        newShelfName = ""
        showingNewShelf = true
    }
}
