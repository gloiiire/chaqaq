import SwiftUI
import PinkhaFFI

// ── Safari-style tab manager ───────────────────────────────────────────────

/// Holds the user's currently-open leaves the way Safari holds its
/// tabs : each tab carries a long-lived `LeafViewModel`, so its
/// in-memory state (title draft, scroll-driven preferences, undo
/// history, pending burst, etc.) survives navigation pops and tab
/// switches. Opening the same doc twice reuses its tab and brings it
/// to the front of the list (MRU ordering).
///
/// Closing happens via the switcher (swipe-left on a card) or
/// explicitly through `close(leafId:)` — back-navigation in the editor
/// does NOT close the tab, matching Safari's behaviour.
///
/// The open-tab list persists across app launches in `UserDefaults`,
/// but VMs are only constructed lazily as docs are first opened in
/// the current session, so cold launches don't pay the cost of
/// instantiating every persisted tab up-front.
@MainActor
@Observable
public final class TabManager {
    /// Observed list of open tabs — driven by the switcher and the
    /// few other views that need to react to opens/closes. Mutated
    /// **asynchronously** (via `Task @MainActor`) to avoid triggering
    /// an Observation feedback loop : NavigationLink eagerly
    /// constructs its destination during view body evaluation, which
    /// is the exact moment any synchronous mutation to an observed
    /// property would re-publish and re-render again, etc.
    public private(set) var openTabs: [LeafTab] = []

    /// In-process VM cache. Returns the same VM for the same leafId on
    /// every call within a session, so back/forward navigation reuses
    /// the same in-memory state. `@ObservationIgnored` — reads from
    /// view body don't trigger re-renders and we don't want SwiftUI
    /// to dirty-mark this map.
    @ObservationIgnored private var vmCache: [String: LeafViewModel] = [:]

    /// LIFO stack of recently-closed tab leafIds (Safari pattern). The
    /// `...` menu in the switcher exposes "Undo close" while this is
    /// non-empty, popping the latest entry back into `openTabs`.
    ///
    /// Capped so a frantic close-all spree doesn't keep VMs alive
    /// forever — older closes age out silently.
    public private(set) var recentlyClosed: [String] = []
    @ObservationIgnored private let recentlyClosedCapacity = 10

    /// MRU list of every leafId the user has *opened* this session (or
    /// across sessions thanks to `persist()`). Unlike `openTabs`, an
    /// entry stays here after the tab is closed — the home's "Recent"
    /// strip reads it so the user sees what they actually consulted
    /// recently, not what was most recently modified.
    public private(set) var recentlyViewed: [String] = []
    @ObservationIgnored private let recentlyViewedCapacity = 50

    @ObservationIgnored private let persistenceKey = "com.pinkha.openTabs.v1"
    @ObservationIgnored private let recentlyViewedKey = "com.pinkha.recentlyViewed.v1"

    public init() {
        if let saved = UserDefaults.standard.array(forKey: recentlyViewedKey) as? [String] {
            recentlyViewed = saved
        }
    }

    /// Returns the live VM for `leafId`, creating one on first access.
    /// **No side effect on `openTabs`** — call this from view bodies
    /// (NavigationLink destinations are evaluated eagerly, so a side
    /// effect here would re-add tabs the user just closed). Use
    /// `markOpened(leafId:)` from an explicit user action when you
    /// want the doc to appear in the switcher.
    @discardableResult
    public func open(leafId: String, api: PinkhaApi) -> LeafViewModel {
        if let cached = vmCache[leafId] { return cached }
        let vm = LeafViewModel(leafId: leafId, api: api)
        // Eager load on first creation. Without this, when `closeAll()`
        // wipes the cache while a LeafView is still on the nav
        // stack, the navigationDestination's next evaluation hands the
        // editor a fresh empty VM whose `.onAppear` (and thus `load()`)
        // never refires — the user sees "Untitled" + blank content and
        // any keystroke saves the EMPTY state back over the real doc,
        // wiping the original. Loading here keeps the VM consistent
        // with disk no matter who triggers the (re)creation.
        vm.load()
        vmCache[leafId] = vm
        return vm
    }

    /// Explicitly marks `leafId` as an open tab in the switcher. Call
    /// from an explicit user action (tap on a doc in the list, push
    /// triggered by `pendingOpenDoc`, etc.), NOT from view-body
    /// evaluation. Safe to call from inside `withAnimation` blocks.
    public func markOpened(leafId: String, api: PinkhaApi) {
        // Ensure the VM exists (no-op if cached).
        _ = open(leafId: leafId, api: api)
        openTabs.removeAll { $0.leafId == leafId }
        openTabs.insert(LeafTab(leafId: leafId,
                                     vm: vmCache[leafId]!), at: 0)
        // Bump to the front of the recently-viewed MRU. Survives
        // close — the home's "Recent" strip reads from this.
        markRecentlyViewed(id: leafId)
    }

    /// MRU-only push : adds `id` to the `recentlyViewed` list without
    /// touching `openTabs` or `vmCache`. Used by `BookView` to
    /// surface freshly-opened books in the Library home Recent strip
    /// without creating a phantom leaf tab for them.
    public func markRecentlyViewed(id: String) {
        recentlyViewed.removeAll { $0 == id }
        recentlyViewed.insert(id, at: 0)
        if recentlyViewed.count > recentlyViewedCapacity {
            recentlyViewed.removeLast(recentlyViewed.count - recentlyViewedCapacity)
        }
        persist()
    }

    /// Bumps an existing tab to the top of the MRU list — call only
    /// from explicit user actions (tap on a card in the switcher),
    /// never during a view body render.
    public func bringToFront(leafId: String) {
        guard let idx = openTabs.firstIndex(where: { $0.leafId == leafId }) else { return }
        let tab = openTabs.remove(at: idx)
        openTabs.insert(tab, at: 0)
        persist()
    }

    /// Removes the tab from the list and drops the VM reference so
    /// the doc's working memory is released. Pushes the leafId onto
    /// `recentlyClosed` so an "Undo" affordance can restore it. Safe
    /// to call on a `leafId` that isn't currently a tab — no-op then.
    public func close(leafId: String) {
        guard openTabs.contains(where: { $0.leafId == leafId }) else { return }
        openTabs.removeAll { $0.leafId == leafId }
        vmCache[leafId] = nil
        // Push onto the undo stack — dedupe to keep the latest only.
        recentlyClosed.removeAll { $0 == leafId }
        recentlyClosed.append(leafId)
        if recentlyClosed.count > recentlyClosedCapacity {
            recentlyClosed.removeFirst(recentlyClosed.count - recentlyClosedCapacity)
        }
        persist()
    }

    /// Wipes every tab — used by the "Close all" affordance in the
    /// switcher's bottom toolbar. All closed docs go onto the undo
    /// stack so a misplaced tap can still be recovered.
    public func closeAll() {
        let closed = openTabs.map(\.leafId)
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
    public func reopenLastClosed(api: PinkhaApi) -> String? {
        guard let leafId = recentlyClosed.popLast() else { return nil }
        markOpened(leafId: leafId, api: api)
        return leafId
    }

    private func persist() {
        let ids = openTabs.map(\.leafId)
        UserDefaults.standard.set(ids, forKey: persistenceKey)
        UserDefaults.standard.set(recentlyViewed, forKey: recentlyViewedKey)
    }
}

/// One Safari-like tab. The id matches `leafId` so navigation paths
/// and switcher selections can address a tab without juggling two
/// identifiers.
public struct LeafTab: Identifiable, Equatable {
    public var id: String { leafId }
    public let leafId: String
    public let vm: LeafViewModel

    public static func == (lhs: LeafTab, rhs: LeafTab) -> Bool {
        lhs.leafId == rhs.leafId
    }
}
