import SwiftUI

// ── Safari-style tab manager ───────────────────────────────────────────────

/// Holds the user's currently-open documents the way Safari holds its
/// tabs : each tab carries a long-lived `DocumentViewModel`, so its
/// in-memory state (title draft, scroll-driven preferences, undo
/// history, pending burst, etc.) survives navigation pops and tab
/// switches. Opening the same doc twice reuses its tab and brings it
/// to the front of the list (MRU ordering).
///
/// Closing happens via the switcher (swipe-left on a card) or
/// explicitly through `close(docId:)` — back-navigation in the editor
/// does NOT close the tab, matching Safari's behaviour.
///
/// The open-tab list persists across app launches in `UserDefaults`,
/// but VMs are only constructed lazily as docs are first opened in
/// the current session, so cold launches don't pay the cost of
/// instantiating every persisted tab up-front.
@MainActor
final class TabManager: ObservableObject {
    /// Published list of open tabs — observed by the switcher and the
    /// few other views that need to react to opens/closes. Mutated
    /// **asynchronously** (via `Task @MainActor`) to avoid triggering
    /// an Observation feedback loop : NavigationLink eagerly
    /// constructs its destination during view body evaluation, which
    /// is the exact moment any synchronous mutation to a `@Published`
    /// property would re-publish and re-render again, etc.
    @Published private(set) var openTabs: [DocumentTab] = []

    /// In-process VM cache. Returns the same VM for the same docId on
    /// every call within a session, so back/forward navigation reuses
    /// the same in-memory state. Not `@Published` — reads from view
    /// body don't trigger re-renders.
    private var vmCache: [String: DocumentViewModel] = [:]

    /// LIFO stack of recently-closed tab docIds (Safari pattern). The
    /// `...` menu in the switcher exposes "Undo close" while this is
    /// non-empty, popping the latest entry back into `openTabs`.
    ///
    /// Capped so a frantic close-all spree doesn't keep VMs alive
    /// forever — older closes age out silently.
    @Published private(set) var recentlyClosed: [String] = []
    private let recentlyClosedCapacity = 10

    private let persistenceKey = "com.pinkha.openTabs.v1"

    init() {}

    /// Returns the live VM for `docId`, creating one on first access.
    /// **No side effect on `openTabs`** — call this from view bodies
    /// (NavigationLink destinations are evaluated eagerly, so a side
    /// effect here would re-add tabs the user just closed). Use
    /// `markOpened(docId:)` from an explicit user action when you
    /// want the doc to appear in the switcher.
    @discardableResult
    func open(docId: String, api: PinkhaApi) -> DocumentViewModel {
        if let cached = vmCache[docId] { return cached }
        let vm = DocumentViewModel(docId: docId, api: api)
        vmCache[docId] = vm
        return vm
    }

    /// Explicitly marks `docId` as an open tab in the switcher. Call
    /// from an explicit user action (tap on a doc in the list, push
    /// triggered by `pendingOpenDoc`, etc.), NOT from view-body
    /// evaluation. Safe to call from inside `withAnimation` blocks.
    func markOpened(docId: String, api: PinkhaApi) {
        // Ensure the VM exists (no-op if cached).
        _ = open(docId: docId, api: api)
        openTabs.removeAll { $0.docId == docId }
        openTabs.insert(DocumentTab(docId: docId,
                                     vm: vmCache[docId]!), at: 0)
        persist()
    }

    /// Bumps an existing tab to the top of the MRU list — call only
    /// from explicit user actions (tap on a card in the switcher),
    /// never during a view body render.
    func bringToFront(docId: String) {
        guard let idx = openTabs.firstIndex(where: { $0.docId == docId }) else { return }
        let tab = openTabs.remove(at: idx)
        openTabs.insert(tab, at: 0)
        persist()
    }

    /// Removes the tab from the list and drops the VM reference so
    /// the doc's working memory is released. Pushes the docId onto
    /// `recentlyClosed` so an "Undo" affordance can restore it. Safe
    /// to call on a `docId` that isn't currently a tab — no-op then.
    func close(docId: String) {
        guard openTabs.contains(where: { $0.docId == docId }) else { return }
        openTabs.removeAll { $0.docId == docId }
        vmCache[docId] = nil
        // Push onto the undo stack — dedupe to keep the latest only.
        recentlyClosed.removeAll { $0 == docId }
        recentlyClosed.append(docId)
        if recentlyClosed.count > recentlyClosedCapacity {
            recentlyClosed.removeFirst(recentlyClosed.count - recentlyClosedCapacity)
        }
        persist()
    }

    /// Wipes every tab — used by the "Close all" affordance in the
    /// switcher's bottom toolbar. All closed docs go onto the undo
    /// stack so a misplaced tap can still be recovered.
    func closeAll() {
        let closed = openTabs.map(\.docId)
        openTabs.removeAll()
        vmCache.removeAll()
        for id in closed {
            recentlyClosed.removeAll { $0 == id }
            recentlyClosed.append(id)
        }
        if recentlyClosed.count > recentlyClosedCapacity {
            recentlyClosed.removeFirst(recentlyClosed.count - recentlyClosedCapacity)
        }
        persist()
    }

    /// Reopens the most recently closed tab — Safari's "Undo close
    /// tab" gesture. Pops from `recentlyClosed`, recreates the VM via
    /// `markOpened`, and the doc lands back at the top of the
    /// switcher's MRU list. No-op when the stack is empty.
    @discardableResult
    func reopenLastClosed(api: PinkhaApi) -> String? {
        guard let docId = recentlyClosed.popLast() else { return nil }
        markOpened(docId: docId, api: api)
        return docId
    }

    private func persist() {
        let ids = openTabs.map(\.docId)
        UserDefaults.standard.set(ids, forKey: persistenceKey)
    }
}

/// One Safari-like tab. The id matches `docId` so navigation paths
/// and switcher selections can address a tab without juggling two
/// identifiers.
struct DocumentTab: Identifiable, Equatable {
    var id: String { docId }
    let docId: String
    let vm: DocumentViewModel

    static func == (lhs: DocumentTab, rhs: DocumentTab) -> Bool {
        lhs.docId == rhs.docId
    }
}
