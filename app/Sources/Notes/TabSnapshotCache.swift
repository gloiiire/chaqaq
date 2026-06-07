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
