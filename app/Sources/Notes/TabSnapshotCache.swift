import SwiftUI
import UIKit

// ── In-memory snapshot cache for tab cards ────────────────────────────────
//
// Stores a `UIImage` per docId — captured when the user navigates away
// from a document — so the switcher's tab cards can display the exact
// content (and scroll position) the user was looking at, matching
// Safari's behaviour.
//
// Backed by `NSCache` so iOS evicts entries automatically under memory
// pressure. Capped at 50 entries / 30 MB to stay light-weight even
// for power users with many open tabs.

@MainActor
final class TabSnapshotCache {
    static let shared = TabSnapshotCache()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 50
        c.totalCostLimit = 30 * 1024 * 1024
        return c
    }()

    private init() {}

    /// Stores `image` keyed by `docId`. Cost = approximate pixel
    /// memory so `NSCache`'s `totalCostLimit` heuristic kicks in
    /// properly.
    func store(_ image: UIImage, for docId: String) {
        let scale = image.scale
        let cost = Int(image.size.width * image.size.height * 4 * scale * scale)
        cache.setObject(image, forKey: docId as NSString, cost: cost)
    }

    func snapshot(for docId: String) -> UIImage? {
        cache.object(forKey: docId as NSString)
    }

    /// Drops the cached snapshot for `docId`. Called from the
    /// switcher when the user closes a tab so memory comes back
    /// immediately.
    func invalidate(_ docId: String) {
        cache.removeObject(forKey: docId as NSString)
    }

    /// Captures the current key window into a `UIImage` and caches it
    /// under `docId`. Use right before transitioning from the doc to
    /// the switcher : guarantees the tab card shows the exact content
    /// + scroll position the user had, even when `viewWillDisappear`
    /// of the underlying DocumentView doesn't fire (fullScreenCover
    /// doesn't reliably trigger it on the covered VC in iOS 26).
    @discardableResult
    func captureCurrentWindow(for docId: String) -> Bool {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows
            .first { $0.isKeyWindow }
        guard let window else { return false }
        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        store(image, for: docId)
        return true
    }
}

// ── In-memory scroll-position cache ───────────────────────────────────────
//
// Sibling to `TabSnapshotCache` : stores the last-seen content offset of
// each doc's editor scroll view, keyed by docId. Restoring the scroll
// position on re-open turns the switcher into a proper task-switcher —
// reopening a doc lands the user exactly where they left off.
//
// Held as a plain `Dictionary` (not `NSCache`) : a CGFloat per doc is
// trivial memory, and we don't want iOS to evict positions under memory
// pressure (snapshot images are a different story).

@MainActor
final class ScrollPositionCache {
    static let shared = ScrollPositionCache()
    private var positions: [String: CGFloat] = [:]

    private init() {}

    func save(_ offset: CGFloat, for docId: String) {
        positions[docId] = offset
    }

    func offset(for docId: String) -> CGFloat? {
        positions[docId]
    }

    func invalidate(_ docId: String) {
        positions.removeValue(forKey: docId)
    }
}

// ── SwiftUI bridge : restore scroll offset on mount ───────────────────────

/// Drop-in invisible host that, on its hosting VC's `viewDidAppear`,
/// finds the largest `UIScrollView` in the key window (= the
/// `UICollectionView` backing the SwiftUI `List`) and restores its
/// content offset to the value cached for `docId`.
///
/// Why a `UIViewControllerRepresentable` rather than a list row :
///  - `viewDidAppear` fires reliably on the VC, while
///    `UIViewRepresentable.updateUIView` may not run before the user
///    sees the top of the doc.
///  - The largest-scroll-view-in-window search is robust against
///    layout depth — we don't depend on the host view being a child
///    of the scrollable hierarchy.
///
/// Place once as `.background` of `documentList` (matching the
/// `DocumentSnapshotHook` pattern). The restorer waits for the
/// `contentSize` to grow large enough to fit the cached offset (List
/// lazy-loads its rows), retrying up to ~1 s, then applies the offset
/// without animation so the user lands "where they left off".
struct ScrollPositionRestorer: UIViewControllerRepresentable {
    let docId: String

    /// Captures the cached target offset **at SwiftUI view init time**
    /// — before the freshly-mounted `List` has a chance to fire its
    /// own `onScrollGeometryChange` with offset 0 and overwrite the
    /// cache. Without this, the new mount's first scroll event lands
    /// before the restorer's `viewDidAppear` runs, and we read back 0.
    @MainActor
    final class Coordinator {
        let target: CGFloat?
        init(docId: String) {
            self.target = ScrollPositionCache.shared.offset(for: docId)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(docId: docId) }

    func makeUIViewController(context: Context) -> ScrollPositionRestorerVC {
        let vc = ScrollPositionRestorerVC()
        vc.targetOffset = context.coordinator.target
        return vc
    }

    func updateUIViewController(_ vc: ScrollPositionRestorerVC, context: Context) {}
}

final class ScrollPositionRestorerVC: UIViewController {
    var targetOffset: CGFloat?
    private var didRestore = false
    private var displayLink: CADisplayLink?
    private var tickCount = 0
    /// First-success state : once we land at the target offset, keep
    /// re-applying for this many frames to resist any layout-pass
    /// reset back to top (vm.load finishing, nav-bar finalising, etc.).
    private var lockedClampedOffset: CGFloat?
    private var lockFramesRemaining = 0
    private static let lockFrames = 30
    /// Hard cap on how many frames we keep polling before giving up
    /// (≈ 1 s at 60 Hz, 0.5 s at 120 Hz). Prevents the link from
    /// staying live on a doc that genuinely doesn't have the cached
    /// offset in its rendered content.
    private static let maxTicks = 60

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Start polling as early as possible — `viewWillAppear` fires
    /// before the navigation transition is even visible to the user,
    /// so the restore is in flight by the time the doc finishes
    /// sliding in. The link polls every screen refresh (~16 ms at
    /// 60 Hz) which is much snappier than the 50 ms async-retry we
    /// had before.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !didRestore, displayLink == nil, targetOffset != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopLink()
    }

    @objc private func tick() {
        tickCount += 1
        if tickCount > Self.maxTicks { stopLink(); return }
        tryRestore()
    }

    @MainActor
    private func tryRestore() {
        guard !didRestore,
              let target = targetOffset, target > 0,
              let window = view.window,
              let scrollView = Self.findLargestScrollView(in: window) else { return }

        // Lock phase : already landed once, just hold the position
        // against any layout-driven reset. Stop if the user grabs the
        // scroll view (they get priority).
        if let locked = lockedClampedOffset {
            if scrollView.isTracking || scrollView.isDragging {
                didRestore = true
                stopLink()
                return
            }
            // Only re-apply if something pushed us back toward the top
            // — never override the user scrolling further down.
            if scrollView.contentOffset.y < locked - 4 {
                scrollView.contentOffset = CGPoint(x: 0, y: locked)
            }
            lockFramesRemaining -= 1
            if lockFramesRemaining <= 0 {
                didRestore = true
                stopLink()
            }
            return
        }

        let maxY = max(0,
                       scrollView.contentSize.height
                       + scrollView.adjustedContentInset.bottom
                       - scrollView.bounds.height)

        // Wait until the List has laid out enough rows to fit the
        // target — otherwise setContentOffset clamps near the top.
        // The display link keeps polling each frame until contentSize
        // catches up (typically 2–4 frames).
        if maxY + scrollView.adjustedContentInset.top < target { return }

        let clamped = min(max(0, target - scrollView.adjustedContentInset.top), maxY)
        // Instant set : the link fires during the NavigationStack push
        // animation (before the user can see the doc), so applying the
        // offset directly means the doc slides into view ALREADY at the
        // saved position — no "page-at-top → scroll-down" flash that
        // an animated set would create.
        scrollView.contentOffset = CGPoint(x: 0, y: clamped)
        // Enter lock phase : keep re-applying for ~500 ms to resist
        // any layout-pass reset (vm.load finishing, nav bar finalising,
        // contentInset adjustments, etc.).
        lockedClampedOffset = clamped
        lockFramesRemaining = Self.lockFrames
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private static func findLargestScrollView(in root: UIView) -> UIScrollView? {
        var biggest: UIScrollView?
        var biggestHeight: CGFloat = 0
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if let sv = v as? UIScrollView, sv.bounds.height > biggestHeight {
                biggest = sv
                biggestHeight = sv.bounds.height
            }
            queue.append(contentsOf: v.subviews)
        }
        return biggest
    }
}

// ── SwiftUI bridge : capture on viewWillDisappear ─────────────────────────

/// Drop-in SwiftUI view that captures the current key window the
/// instant its host VC's `viewWillDisappear` fires. Place it once,
/// invisibly, inside `DocumentView`. The snapshot ends up in
/// `TabSnapshotCache` keyed by `docId`.
///
/// Why a `UIViewControllerRepresentable` : SwiftUI's own
/// `.onDisappear` fires *after* the view has been removed, by which
/// point the window's render tree no longer contains the document
/// we want to capture. `viewWillDisappear` is the last frame the
/// content is still on screen — exactly what Safari uses for tab
/// thumbnails.
struct DocumentSnapshotHook: UIViewControllerRepresentable {
    let docId: String

    func makeUIViewController(context: Context) -> SnapshotHookViewController {
        SnapshotHookViewController(docId: docId)
    }

    func updateUIViewController(_ vc: SnapshotHookViewController, context: Context) {
        vc.docId = docId
    }
}

final class SnapshotHookViewController: UIViewController {
    fileprivate var docId: String

    init(docId: String) {
        self.docId = docId
        super.init(nibName: nil, bundle: nil)
        view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSnapshot()
    }

    /// Capture the current window into a `UIImage` and hand it off
    /// to the cache. We use `drawHierarchy` (which honours Core
    /// Animation transforms and effect views like UIGlassEffect)
    /// rather than `layer.render(in:)` (which doesn't).
    private func captureSnapshot() {
        guard let window = view.window else { return }
        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        TabSnapshotCache.shared.store(image, for: docId)
    }
}
