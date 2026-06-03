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

    enum CreateMode { case note, database }

    func openNewNote() {
        createMode = .note
        newTitle = ""
        showingCreateDoc = true
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
