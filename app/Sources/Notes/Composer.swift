import SwiftUI

// ── Composer state ────────────────────────────────────────────────────────────

/// Owns the presentation state for the global create bubble — sheets,
/// alerts and the create mode picker. Lives at the `ContentView` level so
/// the bubble inside `tabViewBottomAccessory` can drive create / trash /
/// import flows regardless of which tab is currently selected.
@MainActor
final class Composer: ObservableObject {
    /// Whether the document/database title prompt is on screen.
    @Published var showingCreateDoc = false
    /// Whether the new-folder alert is on screen.
    @Published var showingNewFolder = false
    /// Whether the trash sheet is on screen.
    @Published var showingTrash = false
    /// Whether the Safari-tab-style "All documents" full-screen
    /// switcher is on screen — opened from the overflow menu in the
    /// bottom accessory.
    @Published var showingAllDocs = false
    /// Whether the Notion import sheet is on screen.
    @Published var showingNotionImport = false
    /// Whether the Bear import sheet is on screen.
    @Published var showingBearImport = false
    /// Whether the Craft TextBundle import sheet is on screen.
    @Published var showingCraftTextBundleImport = false
    /// Whether the Craft combined import sheet is on screen.
    @Published var showingCraftCombinedImport = false
    /// First-step Delete All confirmation alert.
    @Published var showingDeleteAllConfirm = false
    /// Second-step Delete All confirmation alert.
    @Published var showingDeleteAllConfirm2 = false
    /// Title draft for the create document sheet.
    @Published var newTitle = ""
    /// Name draft for the new-folder alert.
    @Published var newFolderName = ""
    /// Which kind of document the create sheet should produce.
    @Published var createMode: CreateMode = .note
    /// Where the next `New …` should land. Driven by the navigation
    /// stack — `FolderView` flips it to `.folder(id)` on appear (and
    /// back to `.root` on disappear), `DocumentView` flips it to
    /// `.document(id)`. The home, databases and inbox screens leave the
    /// default `.root`, so anything created from there lands at the
    /// top of the workspace.
    @Published var currentContext: CreationContext = .root
    /// Signals that a child page has just been created from inside a
    /// document and needs to be embedded as a `Page` block in the active
    /// editor. The DocumentView observes this and routes the insertion
    /// through its VM — otherwise the next burst flush would overwrite
    /// a block written behind the VM's back via a direct FFI call.
    @Published var pendingChildPage: PendingChildPage? = nil
    /// Signals that a newly-created note should be pushed onto the
    /// Notes navigation stack right after the create sheet dismisses,
    /// so the user lands in the editor instead of back on the home
    /// list. Only set for `.root` / `.folder` contexts — the
    /// `.document` context routes through `pendingChildPage` instead.
    @Published var pendingOpenDoc: String? = nil

    enum CreateMode { case note, database }

    /// Anchor for context-aware creation — the bubble inherits the
    /// "where am I?" from the foreground view so a new note created
    /// while looking at folder "K" lands inside "K", not at root.
    enum CreationContext: Equatable {
        case root
        case folder(id: String)
        case document(id: String)
    }

    /// Payload of `pendingChildPage`. The parent doc id lets the active
    /// `DocumentView` filter — only the editor showing `parentDocId`
    /// should react and consume the signal.
    struct PendingChildPage: Equatable {
        let parentDocId: String
        let childDocId: String
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

    func openNewDatabase() {
        createMode = .database
        newTitle = ""
        showingCreateDoc = true
    }

    func openNewFolder() {
        newFolderName = ""
        showingNewFolder = true
    }
}
