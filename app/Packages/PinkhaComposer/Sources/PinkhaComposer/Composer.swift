import SwiftUI

// ── Composer state ────────────────────────────────────────────────────────────

/// Owns the presentation state for the global create bubble — sheets,
/// alerts and the create mode picker. Lives at the `ContentView` level so
/// the bubble inside `tabViewBottomAccessory` can drive create / trash /
/// import flows regardless of which tab is currently selected.
///
/// Lives in its own package so feature modules (LeafFeature,
/// BookFeature, LibraryFeature) can depend on it without depending on
/// each other — breaks the Library↔Leaf cycle that previously blocked
/// the multi-target split. Wiring to UIApplication shortcut items
/// (`bindQuickActions`) is in the app target as a separate extension
/// because it touches `AppDelegate.pendingShortcutType`.
@MainActor
@Observable
public final class Composer {
    /// Whether the leaf/book title prompt is on screen.
    public var showingCreateLeaf = false
    /// Whether the new-shelf alert is on screen.
    public var showingNewShelf = false
    /// Whether the trash sheet is on screen.
    public var showingTrash = false
    /// Whether the Safari-tab-style "All leaves" full-screen
    /// switcher is on screen — opened from the overflow menu in the
    /// bottom accessory.
    public var showingAllLeaves = false
    /// Whether the Notion import sheet is on screen.
    public var showingNotionImport = false
    /// Whether the Bear import sheet is on screen.
    public var showingBearImport = false
    /// Whether the Craft TextBundle import sheet is on screen.
    public var showingCraftTextBundleImport = false
    /// Whether the Craft combined import sheet is on screen.
    public var showingCraftCombinedImport = false
    /// First-step Delete All confirmation alert.
    public var showingDeleteAllConfirm = false
    /// Second-step Delete All confirmation alert.
    public var showingDeleteAllConfirm2 = false
    /// Title draft for the create leaf sheet.
    public var newTitle = ""
    /// Name draft for the new-shelf alert.
    public var newShelfName = ""
    /// Which kind of leaf the create sheet should produce.
    public var createMode: CreateMode = .leaf
    /// Where the next `New …` should land. Driven by the navigation
    /// stack — `ShelfView` flips it to `.shelf(id)` on appear (and
    /// back to `.root` on disappear), `LeafView` flips it to
    /// `.leaf(id)`. The home, books and inbox screens leave the
    /// default `.root`, so anything created from there lands at the
    /// top of the library.
    public var currentContext: CreationContext = .root
    /// Signals that a child leaf has just been created from inside a
    /// leaf and needs to be embedded as a `Page` block in the active
    /// editor. The LeafView observes this and routes the insertion
    /// through its VM — otherwise the next burst flush would overwrite
    /// a block written behind the VM's back via a direct FFI call.
    public var pendingChildPage: PendingChildPage? = nil
    /// Signals that a newly-created leaf should be pushed onto the
    /// Library navigation stack right after the create sheet dismisses,
    /// so the user lands in the editor instead of back on the home
    /// list. Only set for `.root` / `.shelf` contexts — the
    /// `.leaf` context routes through `pendingChildPage` instead.
    public var pendingOpenLeaf: String? = nil

    /// NotificationCenter signal — when the switcher dismisses with
    /// zero open tabs, posts this so the active `NavigationStack`
    /// pops to root. Going through `NotificationCenter` instead of an
    /// observation-driven counter sidesteps the SwiftUI binding
    /// propagation quirks we hit (`.onChange` not firing reliably
    /// while a fullScreenCover is dismissing).
    public static let popHomeNotification = Notification.Name("pinkha.popHomeRequest")

    /// Posted by the LeafView breadcrumb when the user taps an
    /// ancestor segment. `userInfo["leafId"]` carries the target —
    /// LibraryView truncates its NavigationStack `path` to keep
    /// only entries up to and including that doc.
    public static let popToDocNotification = Notification.Name("pinkha.popToDoc")

    /// Posted whenever a leaf's title is persisted (FFI write
    /// succeeded). `userInfo["leafId"]` carries the doc that changed.
    /// Used by every mounted LeafView to refresh its
    /// `docMetaById` cache — otherwise a child's breadcrumb keeps
    /// showing the old parent title until the user pops to root.
    public static let docTitleChangedNotification = Notification.Name("pinkha.docTitleChanged")

    /// Currently-selected pinkha tab. Bound to the root `TabView`
    /// `selection:` so we can programmatically switch tabs from
    /// anywhere (e.g. the switcher's ✓ button forcing a return to
    /// the Library after closing all open leaves).
    public var selectedTab: TabKind = .leaves

    // NavigationStack path lives back in `LibraryView.@State` because
    // `NavigationStack(path: $model.path)` is buggy in iOS — it doesn't
    // visibly pop when the binding is mutated, while `@State` does.

    /// Bump this to force-recreate `LibraryView` via `.id(leavesHomeKey)`.
    /// Used by the switcher's ✓ button to nuke a stuck NavStack
    /// (Apple SwiftUI bug : path mutation from outside doesn't always
    /// visibly pop even when the binding fires). Recreating the view
    /// instantiates fresh `@State` → path starts at `[]` → home shown.
    public var leavesHomeKey: Int = 0

    public init() {}

    /// The four pinkha tabs. `rawValue` is stable for `Codable` use if
    /// we ever persist the last-selected tab; the enum itself is
    /// `Hashable` so it works as a `TabView` selection binding.
    public enum TabKind: String, Hashable, Codable {
        case leaves, books, inbox, search
    }

    public enum CreateMode { case leaf, book }

    /// Anchor for context-aware creation — the bubble inherits the
    /// "where am I?" from the foreground view so a new leaf created
    /// while looking at shelf "K" lands inside "K", not at root.
    ///
    /// `.book(id:)` means "the user is inside a Book table view".
    /// A new leaf in this context becomes a row of that book (via
    /// `createLeafInBook`). New books/shelves fall back to root —
    /// the bubble greys them out in PRO-57 to make this honest.
    public enum CreationContext: Equatable {
        case root
        case shelf(id: String)
        case leaf(id: String)
        case book(id: String)
    }

    /// Payload of `pendingChildPage`. The parent doc id lets the active
    /// `LeafView` filter — only the editor showing `parentLeafId`
    /// should react and consume the signal.
    public struct PendingChildPage: Equatable {
        public let parentLeafId: String
        public let childLeafId: String

        public init(parentLeafId: String, childLeafId: String) {
            self.parentLeafId = parentLeafId
            self.childLeafId = childLeafId
        }
    }

    public func openNewLeaf() {
        createMode = .leaf
        newTitle = ""
        showingCreateLeaf = true
    }

    public func openNewBook() {
        createMode = .book
        newTitle = ""
        showingCreateLeaf = true
    }

    public func openNewShelf() {
        newShelfName = ""
        showingNewShelf = true
    }
}
