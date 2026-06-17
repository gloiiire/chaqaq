import SwiftUI
import UIKit
import PinkhaFFI

// ── Safari-style switcher (gesture-first architecture) ─────────────────────
//
// Rewritten after the UICollectionView / UICollectionViewCell approach
// failed to deliver a reliable swipe-to-close because of touch-routing
// conflicts between the collection view's built-in gestures, the cell
// selection mechanism, and our overlay gestures.
//
// This implementation mirrors what `SFTabSwitcher` does in MobileSafari
// (cf. `docs/SAFARI-TAB-GRID-RE.md`) : a single master view owns ALL
// touch routing through one `UIPanGestureRecognizer` + one
// `UITapGestureRecognizer`. Cells are plain `UIView`s with no gestures
// of their own. The X button is detected by hit-testing in the tap
// handler, not by being a UIButton (which races against cell-tap).
//
// Architecture:
//
//   SafariSwitcherView : UIView
//     ├── contentView : UIView     ← holds all cells, translated for "scroll"
//     │     └── TabCardView × N    ← pure UIView, no gestures
//     └── closingItemsContainerView ← overlay for closing-cell replicas
//
//   Master gestures (on `self`):
//     - UIPanGestureRecognizer  ← scroll OR swipe-close (mode decided at .changed)
//     - UITapGestureRecognizer  ← cell-open OR X-close (decided by hit-test)

/// SwiftUI wrapper.
public struct SafariSwitcher: UIViewRepresentable {
    public init(items: [WorkspaceItem], api: PinkhaApi?, accent: Color,
                onSelect: @escaping (String) -> Void,
                onClose: @escaping (String) -> Void) {
        self.items = items; self.api = api; self.accent = accent
        self.onSelect = onSelect; self.onClose = onClose
    }
    public let items: [WorkspaceItem]
    public let api: PinkhaApi?
    public let accent: Color
    public let onSelect: (String) -> Void
    public let onClose: (String) -> Void

    public func makeUIView(context: Context) -> SafariSwitcherView {
        let v = SafariSwitcherView()
        v.onSelect = onSelect
        v.onClose = onClose
        return v
    }

    public func updateUIView(_ v: SafariSwitcherView, context: Context) {
        v.onSelect = onSelect
        v.onClose = onClose
        v.update(items: items, api: api)
    }
}

// ── Master view ────────────────────────────────────────────────────────────

public final class SafariSwitcherView: UIView {
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    // ── Subviews ──────────────────────────────────────────────────────────
    private let contentView = UIView()
    private let closingContainer: UIView = {
        let v = UIView()
        v.isUserInteractionEnabled = false
        return v
    }()

    // ── Data ──────────────────────────────────────────────────────────────
    private var items: [WorkspaceItem] = []
    private var cells: [TabCardView] = []
    private var api: PinkhaApi?

    // ── Layout state ──────────────────────────────────────────────────────
    private var columns = 2
    private let columnSpacing: CGFloat = 14
    private let rowSpacing: CGFloat = 22
    private let cellAspect: CGFloat = 1.42          // h/w — taller cards, more
                                                    // Safari-like (page screenshot aspect)
    private let contentPadding = UIEdgeInsets(top: 70, left: 16, bottom: 130, right: 16)
    private var contentHeight: CGFloat = 0

    // Vertical "scroll" : we slide contentView via transform.translationY.
    private var scrollOffset: CGFloat = 0
    private var scrollVelocity: CGFloat = 0
    private var inertiaDisplayLink: CADisplayLink?

    // ── Gesture state ─────────────────────────────────────────────────────
    private enum Mode { case undecided, scrolling, swipingCell(Int) }
    private var mode: Mode = .undecided
    private var panStartOffset: CGFloat = 0
    private var lastPanY: CGFloat = 0
    private var lastHapticZone = 0

    // ── Init ──────────────────────────────────────────────────────────────
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.frame = bounds
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        closingContainer.frame = bounds
        closingContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(contentView)
        addSubview(closingContainer)

        // Master gestures
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError() }

    // ── Public API ────────────────────────────────────────────────────────
    func update(items: [WorkspaceItem], api: PinkhaApi?) {
        self.items = items
        self.api = api
        rebuildCells()
        setNeedsLayout()
    }

    // ── Cell rebuild + reuse ──────────────────────────────────────────────
    private func rebuildCells() {
        // Diff by id : reuse existing cells when possible, remove stale,
        // add new. Keeps loader tasks alive for cells that survived.
        let existingById: [String: TabCardView] = Dictionary(
            uniqueKeysWithValues: cells.map { ($0.itemId, $0) })

        var newCells: [TabCardView] = []
        var keepIds: Set<String> = []
        for item in items {
            keepIds.insert(item.id)
            if let cell = existingById[item.id] {
                cell.configure(item: item, api: api)
                newCells.append(cell)
            } else {
                let cell = TabCardView()
                cell.configure(item: item, api: api)
                contentView.addSubview(cell)
                newCells.append(cell)
            }
        }
        for (id, cell) in existingById where !keepIds.contains(id) {
            cell.cancelLoader()
            cell.removeFromSuperview()
        }
        cells = newCells
    }

    // ── Layout ────────────────────────────────────────────────────────────
    public override func layoutSubviews() {
        super.layoutSubviews()
        recomputeColumnsAndLayoutCells()
        applyScrollOffset(animated: false)
    }

    private func recomputeColumnsAndLayoutCells() {
        let totalWidth = bounds.width
        let usable = totalWidth - contentPadding.left - contentPadding.right
        // Aim for ~175 pt per column, clamp 2–4.
        let target = floor((usable + columnSpacing) / (175 + columnSpacing))
        columns = max(2, min(4, Int(target)))

        let cellWidth = (usable - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = cellWidth * cellAspect

        for (i, cell) in cells.enumerated() {
            let row = i / columns
            let col = i % columns
            let x = contentPadding.left + CGFloat(col) * (cellWidth + columnSpacing)
            let y = contentPadding.top + CGFloat(row) * (cellHeight + rowSpacing)
            cell.frame = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
        }

        let rows = (cells.count + columns - 1) / columns
        let lastRowBottom = contentPadding.top
            + CGFloat(rows) * cellHeight
            + CGFloat(max(0, rows - 1)) * rowSpacing
        contentHeight = lastRowBottom + contentPadding.bottom

        // Clamp scroll offset to new content height.
        scrollOffset = clampedScrollOffset(scrollOffset)
    }

    // ── Scrolling ─────────────────────────────────────────────────────────

    /// `scrollOffset = 0` means top. Positive values mean scrolled
    /// down (= contentView translated UP by that many points).
    private func clampedScrollOffset(_ raw: CGFloat) -> CGFloat {
        let maxOffset = max(0, contentHeight - bounds.height)
        return max(0, min(raw, maxOffset))
    }

    private func applyScrollOffset(animated: Bool) {
        let apply = { [self] in
            contentView.transform = CGAffineTransform(translationX: 0, y: -scrollOffset)
        }
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut,
                           animations: apply)
        } else { apply() }
    }

    private func startInertia(velocity: CGFloat) {
        scrollVelocity = velocity
        inertiaDisplayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(stepInertia))
        link.add(to: .main, forMode: .common)
        inertiaDisplayLink = link
    }

    @objc private func stepInertia() {
        let dt: CGFloat = 1.0 / 60.0
        let deceleration: CGFloat = 0.95         // per frame; ~UIScrollView normal
        scrollVelocity *= deceleration
        let nextOffset = clampedScrollOffset(scrollOffset - scrollVelocity * dt)
        let hitEdge = nextOffset != scrollOffset - scrollVelocity * dt
        scrollOffset = nextOffset
        applyScrollOffset(animated: false)
        if abs(scrollVelocity) < 10 || hitEdge {
            inertiaDisplayLink?.invalidate()
            inertiaDisplayLink = nil
        }
    }

    private func stopInertia() {
        inertiaDisplayLink?.invalidate()
        inertiaDisplayLink = nil
        scrollVelocity = 0
    }

    // ── Hit test helpers ──────────────────────────────────────────────────

    /// Find the cell currently under `point` (point is in *self* coords,
    /// not contentView coords — we translate by `scrollOffset` manually).
    private func cellIndex(atSelfPoint point: CGPoint) -> Int? {
        let cvPoint = CGPoint(x: point.x, y: point.y + scrollOffset)
        for (i, cell) in cells.enumerated() {
            if cell.frame.contains(cvPoint) { return i }
        }
        return nil
    }

    /// Whether `point` (in self coords) hits the X-close affordance of
    /// the cell at `index`. Hit area is extended by 14 pt around the
    /// visible button so misses don't fall through to cell-tap.
    private func isCloseTapHit(at point: CGPoint, cellIndex index: Int) -> Bool {
        guard index < cells.count else { return false }
        let cell = cells[index]
        let cvPoint = CGPoint(x: point.x, y: point.y + scrollOffset)
        let closeFrame = cell.closeButtonFrameInSuperview.insetBy(dx: -14, dy: -14)
        return closeFrame.contains(cvPoint)
    }

    // ── Pan gesture (master) ──────────────────────────────────────────────

    @objc private func onPan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: self)
        switch pan.state {
        case .began:
            stopInertia()
            mode = .undecided
            panStartOffset = scrollOffset
            lastPanY = pan.location(in: self).y
            lastHapticZone = 0

        case .changed:
            switch mode {
            case .undecided:
                // First substantial movement decides : horizontal swipe
                // on a cell vs vertical scroll. Threshold 8 pt either
                // direction is enough to commit.
                if abs(translation.x) > 8 || abs(translation.y) > 8 {
                    if abs(translation.x) > abs(translation.y) {
                        // Horizontal — only commit to cell-swipe if the
                        // touch started on a cell.
                        let startPoint = CGPoint(
                            x: pan.location(in: self).x - translation.x,
                            y: pan.location(in: self).y - translation.y)
                        if let idx = cellIndex(atSelfPoint: startPoint) {
                            mode = .swipingCell(idx)
                        } else {
                            mode = .scrolling
                        }
                    } else {
                        mode = .scrolling
                    }
                }

            case .scrolling:
                scrollOffset = clampedScrollOffset(panStartOffset - translation.y)
                applyScrollOffset(animated: false)

            case .swipingCell(let idx):
                guard idx < cells.count else { return }
                let cell = cells[idx]
                // Follow finger leftward only (Safari ignores rightward
                // drags on a tab card).
                let dx = min(translation.x, 0)
                cell.transform = CGAffineTransform(translationX: dx, y: 0)
                // Crescendo haptic.
                if cell.bounds.width > 0 {
                    let progress = abs(dx) / (cell.bounds.width * 0.5)
                    crescendoHaptic(progress: progress)
                }
            }

        case .ended, .cancelled, .failed:
            switch mode {
            case .scrolling:
                let velocity = pan.velocity(in: self).y
                if abs(velocity) > 50 {
                    startInertia(velocity: velocity)
                }
            case .swipingCell(let idx):
                guard idx < cells.count else { break }
                let cell = cells[idx]
                let dx = translation.x
                let vx = pan.velocity(in: self).x
                let projected = dx + Self.projection(velocity: vx)
                let commitThreshold: CGFloat = max(40, cell.bounds.width * 0.35)
                if dx < -commitThreshold || projected < -commitThreshold {
                    commitClose(cellIndex: idx, swipeVelocity: vx)
                } else {
                    cell.snapBack()
                }
            case .undecided:
                break
            }
            mode = .undecided
            lastHapticZone = 0

        default: break
        }
    }

    private func crescendoHaptic(progress: CGFloat) {
        let zone = min(3, Int(progress / 0.25))
        if zone > lastHapticZone {
            let intensities: [CGFloat] = [0.0, 0.4, 0.6, 1.0]
            UIImpactFeedbackGenerator(style: .soft)
                .impactOccurred(intensity: intensities[zone])
            lastHapticZone = zone
        }
    }

    private static func projection(velocity: CGFloat) -> CGFloat {
        let deceleration = UIScrollView.DecelerationRate.normal.rawValue
        return (velocity / 1000.0) * deceleration / (1.0 - deceleration)
    }

    // ── Tap gesture (master) ──────────────────────────────────────────────

    @objc private func onTap(_ tap: UITapGestureRecognizer) {
        let p = tap.location(in: self)
        guard let idx = cellIndex(atSelfPoint: p) else { return }
        if isCloseTapHit(at: p, cellIndex: idx) {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            commitClose(cellIndex: idx)
        } else {
            let item = items[idx]
            if case .leaf(let doc) = item {
                onSelect?(doc.id)
            }
        }
    }

    // ── Close pipeline (Safari overlay container pattern) ────────────────

    private func commitClose(cellIndex idx: Int, swipeVelocity: CGFloat = 0) {
        guard idx < cells.count, idx < items.count else { return }
        let cell = cells[idx]
        let id = items[idx].id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // (a) Snapshot the cell's frame into the closing-container's
        //     coordinate space, accounting for scrollOffset.
        let cellFrameInSelf = CGRect(x: cell.frame.minX,
                                     y: cell.frame.minY - scrollOffset,
                                     width: cell.frame.width,
                                     height: cell.frame.height)
        let currentDx = cell.transform.tx

        // (b) Render replica & place in overlay container.
        let replica = cell.snapshotView(afterScreenUpdates: false)
            ?? UIView(frame: cellFrameInSelf)
        replica.frame = cellFrameInSelf.offsetBy(dx: currentDx, dy: 0)
        // Set the anchor point so rotation pivots near the upper-left
        // corner (the "fling away" feel) rather than the centre. We
        // also offset the frame to compensate for the anchor change.
        replica.layer.anchorPoint = CGPoint(x: 0.3, y: 0.3)
        replica.frame = CGRect(
            x: replica.frame.minX - replica.frame.width * 0.2,
            y: replica.frame.minY - replica.frame.height * 0.2,
            width: replica.frame.width, height: replica.frame.height)
        closingContainer.addSubview(replica)

        // (c) Hide + remove the real cell.
        cell.removeFromSuperview()
        cells.remove(at: idx)
        items.remove(at: idx)

        // (d) Reflow remaining cells with a Safari-grade bouncy spring.
        //     `springDuration: 0.55` + `bounce: 0.28` gives the
        //     playful overshoot Safari uses; the swipe's velocity
        //     carries into the spring so a flick + close feels
        //     physically continuous.
        let reflowVelocity = max(0, min(2.0, abs(swipeVelocity) / 1000))
        UIView.animate(springDuration: 0.55,
                       bounce: 0.28,
                       initialSpringVelocity: reflowVelocity,
                       options: [.allowUserInteraction]) { [self] in
            recomputeColumnsAndLayoutCells()
        }

        // (e) Notify model + drop cached snapshot to reclaim memory.
        onClose?(id)
        TabSnapshotCache.shared.invalidate(id)

        // (f) Animate replica off-screen with Safari's "fling" feel :
        //     compound translate-left + slight downward + scale-down +
        //     a few degrees of CCW rotation. Each piece contributes
        //     weight; a plain translate looks lifeless by comparison.
        let exitDistance = -bounds.width * 1.4
        let exitAnimator = UIViewPropertyAnimator(
            duration: 0.34,
            controlPoint1: CGPoint(x: 0.35, y: 0.0),      // accelerate
            controlPoint2: CGPoint(x: 0.85, y: 0.45))
        exitAnimator.addAnimations {
            replica.transform = CGAffineTransform.identity
                .translatedBy(x: exitDistance, y: 30)
                .scaledBy(x: 0.86, y: 0.86)
                .rotated(by: -.pi / 30)                    // ~6° CCW
            replica.alpha = 0
        }
        exitAnimator.addCompletion { _ in replica.removeFromSuperview() }
        exitAnimator.startAnimation()
    }
}

// ── UIGestureRecognizerDelegate ───────────────────────────────────────────

extension SafariSwitcherView: UIGestureRecognizerDelegate {
    // We own everything : no need for simultaneous recognition with
    // anything. Default delegate behavior is fine. We do allow tap +
    // pan to coexist (iOS already distinguishes them by movement).
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith
                           otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// ── Pure UIKit card view (Safari-fidelity visual) ─────────────────────────

final class TabCardView: UIView {
    private(set) var itemId: String = ""
    private var loaderTask: Task<Void, Never>?

    // Layout constants tuned to match Safari iOS 26's tab card.
    private static let cornerRadius: CGFloat = 22       // larger continuous curve
    private static let coverHeight: CGFloat = 60
    private static let cardBottomLabelGap: CGFloat = 10
    private static let belowLabelHeight: CGFloat = 22
    private static let closeButtonSize: CGFloat = 30    // bigger, more visible
    private static let closeButtonInset: CGFloat = 8    // distance from card corner

    // Card container : rounded, secondary-system background.
    private let cardContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.secondarySystemBackground
        v.layer.cornerRadius = cornerRadius
        v.layer.cornerCurve = .continuous
        v.layer.borderColor = UIColor.white.withAlphaComponent(0.06).cgColor
        v.layer.borderWidth = 0.5
        v.layer.masksToBounds = true
        return v
    }()

    private let shadowLayer: UIView = {
        let v = UIView()
        v.backgroundColor = .clear
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.22
        v.layer.shadowRadius = 8
        v.layer.shadowOffset = CGSize(width: 0, height: 3)
        return v
    }()

    /// Visual-only X button. The master `SafariSwitcherView` detects
    /// taps on this region in its tap handler — there's no
    /// `UIButton.touchUpInside` here precisely so we don't race against
    /// the master tap.
    private let closeView: UIView = {
        let v = UIView()
        // Slightly lighter than `tertiarySystemBackground` so the X
        // stands out against the dark card body (matches Safari's
        // "subtle but visible" close affordance).
        v.backgroundColor = UIColor(white: 0.32, alpha: 0.9)
        v.layer.cornerRadius = TabCardView.closeButtonSize / 2
        v.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
        v.layer.borderWidth = 0.5
        v.isUserInteractionEnabled = false   // master handles hit-testing
        let img = UIImageView(image: UIImage(systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)))
        img.tintColor = UIColor.white.withAlphaComponent(0.85)
        img.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(img)
        NSLayoutConstraint.activate([
            img.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            img.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }()

    // ── Body (live thumbnail OR cover+snippet fallback) ──────────────────

    /// Live thumbnail of the doc at the user's last scroll position.
    /// Captured by `LeafSnapshotHook` in `LeafView`. Takes the
    /// full body when available — Safari pattern.
    private let liveThumbnailView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.anchorPoint = .zero
        return iv
    }()

    private let coverImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        return iv
    }()

    private let snippetLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 9.5)
        // `.label` (primary) — `.secondaryLabel` rendered the snippet
        // in flat grey which read as "this card lost its formatting".
        // Until we load attributed text that preserves the doc's
        // inline colours, plain primary text at least matches the
        // visual weight of cards that DO have a live thumbnail.
        l.textColor = .label
        l.numberOfLines = 0
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    // ── Below-card label (favicon + title, à la Safari) ──────────────────

    /// Emoji icon for docs that set one. `nil` text when the doc has
    /// no emoji (then `belowIconImageView` takes over with an SF Symbol).
    private let belowIcon: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 15)
        l.textAlignment = .center
        return l
    }()

    /// SF Symbol fallback shown when the doc has no emoji. Using a
    /// dedicated `UIImageView` (instead of attaching the symbol via
    /// `NSTextAttachment` to `belowIcon`) is reliable — the attached
    /// variant was rendering nothing on iOS 26 in some cells.
    private let belowIconImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.tintColor = .secondaryLabel
        iv.isHidden = true
        return iv
    }()

    private let belowTitle: UILabel = {
        let l = UILabel()
        // Safari uses system regular ~15 pt below the thumbnail.
        l.font = .systemFont(ofSize: 15, weight: .regular)
        l.textColor = .label
        l.numberOfLines = 1
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false   // master handles everything

        addSubview(shadowLayer)
        shadowLayer.addSubview(cardContainer)
        cardContainer.addSubview(coverImageView)
        cardContainer.addSubview(snippetLabel)
        cardContainer.addSubview(liveThumbnailView)
        // X is a floating overlay on the card body, NOT inside a
        // header strip. Matches Safari : the card shows the page
        // content full-bleed, with the close affordance as a corner
        // chip.
        addSubview(closeView)
        addSubview(belowIcon)
        addSubview(belowIconImageView)
        addSubview(belowTitle)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let cardH = bounds.height - Self.belowLabelHeight - Self.cardBottomLabelGap

        shadowLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: cardH)
        cardContainer.frame = shadowLayer.bounds
        shadowLayer.layer.shadowPath = UIBezierPath(
            roundedRect: shadowLayer.bounds, cornerRadius: Self.cornerRadius).cgPath

        // Floating X chip in the top-right corner of the card (Safari
        // pattern : no header strip, the card body shows content
        // full-bleed and the close affordance overlays the corner).
        let closeSize = Self.closeButtonSize
        closeView.frame = CGRect(
            x: bounds.width - closeSize - Self.closeButtonInset,
            y: Self.closeButtonInset,
            width: closeSize, height: closeSize)

        // Body fills the entire card.
        let bodyTop: CGFloat = 0
        let bodyHeight = cardContainer.bounds.height

        if liveThumbnailView.image != nil {
            coverImageView.frame = .zero
            snippetLabel.frame = .zero
            coverImageView.isHidden = true
            snippetLabel.isHidden = true
            liveThumbnailView.isHidden = false
            liveThumbnailView.frame = CGRect(
                x: 0, y: bodyTop,
                width: cardContainer.bounds.width, height: bodyHeight)
        } else {
            liveThumbnailView.isHidden = true
            coverImageView.isHidden = false
            snippetLabel.isHidden = false
            let hasCover = coverImageView.image != nil
            let coverH: CGFloat = hasCover ? Self.coverHeight : 0
            coverImageView.frame = CGRect(
                x: 0, y: bodyTop,
                width: cardContainer.bounds.width, height: coverH)
            // Snippet starts a bit below the X to avoid running under
            // it. Anchor to the top so the preview reads like a page
            // beginning.
            let snippetTop = bodyTop + coverH + (hasCover ? 10 : 14)
            let snippetH = max(0, cardContainer.bounds.height - snippetTop - 12)
            snippetLabel.frame = CGRect(
                x: 12, y: snippetTop,
                width: cardContainer.bounds.width - 24, height: snippetH)
        }

        // Below-card favicon + title (Safari "tab label" pattern).
        // Emoji label and SF Symbol image view share the same slot —
        // only one is visible at a time (set in `configure`).
        let belowY = cardH + Self.cardBottomLabelGap
        let iconSlot = CGRect(
            x: 4, y: belowY, width: 22, height: Self.belowLabelHeight)
        belowIcon.frame = iconSlot
        belowIconImageView.frame = iconSlot.insetBy(dx: 3, dy: 3)
        belowTitle.frame = CGRect(
            x: iconSlot.maxX + 6, y: belowY,
            width: bounds.width - iconSlot.maxX - 10,
            height: Self.belowLabelHeight)
    }

    /// Frame of the X-close affordance, expressed in our *superview*'s
    /// coordinate space. `closeView` is a direct subview of `self`
    /// (no header wrapper), so its frame is already in our coordinate
    /// space — we just shift by `frame.origin` to reach the superview.
    var closeButtonFrameInSuperview: CGRect {
        let f = closeView.frame
        return CGRect(x: frame.minX + f.minX,
                       y: frame.minY + f.minY,
                       width: f.width, height: f.height)
    }

    func configure(item: WorkspaceItem, api: PinkhaApi?) {
        itemId = item.id
        let title = item.titlePlain.isEmpty ? String(localized: "Untitled") : item.titlePlain
        belowTitle.text = title

        // Below-card favicon : doc emoji (UILabel) or SF Symbol
        // (UIImageView fallback). Only one is visible at a time.
        let symbolCfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        switch item {
        case .leaf(let doc):
            if let icon = doc.icon, !icon.isEmpty {
                belowIcon.text = icon
                belowIcon.isHidden = false
                belowIconImageView.isHidden = true
            } else {
                belowIcon.text = nil
                belowIcon.isHidden = true
                belowIconImageView.image = UIImage(
                    systemName: "doc.text", withConfiguration: symbolCfg)
                belowIconImageView.isHidden = false
            }
        case .book:
            belowIcon.text = nil
            belowIcon.isHidden = true
            belowIconImageView.image = UIImage(
                systemName: "tablecells", withConfiguration: symbolCfg)
            belowIconImageView.isHidden = false
        }

        // Live thumbnail wins if the user has visited this doc — the
        // snapshot was captured at their last scroll position.
        liveThumbnailView.image = TabSnapshotCache.shared.snapshot(for: item.id)

        if case .leaf(let doc) = item,
           let coverString = doc.cover, !coverString.isEmpty,
           let image = Self.coverImage(from: coverString) {
            coverImageView.image = image
        } else {
            coverImageView.image = nil
        }

        snippetLabel.text = ""
        if case .leaf(let doc) = item, let api = api {
            loaderTask?.cancel()
            let leafId = doc.id
            loaderTask = Task { [weak self] in
                let snippet = await Self.loadSnippet(api: api, leafId: leafId)
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    if self.itemId == leafId { self.snippetLabel.text = snippet }
                }
            }
        } else if case .book = item {
            snippetLabel.text = String(localized: "Empty book")
        }

        setNeedsLayout()
    }

    func cancelLoader() {
        loaderTask?.cancel()
        loaderTask = nil
    }

    func snapBack() {
        UIView.animate(withDuration: 0.32,
                       delay: 0,
                       usingSpringWithDamping: 0.78,
                       initialSpringVelocity: 0,
                       options: [.allowUserInteraction]) {
            self.transform = .identity
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────
    private static func symbol(_ name: String, size: CGFloat, color: UIColor) -> NSAttributedString {
        let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let image = UIImage(systemName: name, withConfiguration: cfg)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        let attachment = NSTextAttachment()
        attachment.image = image
        return NSAttributedString(attachment: attachment)
    }

    private static func coverImage(from raw: String) -> UIImage? {
        if let asset = UIImage(named: raw) { return asset }
        if raw.hasPrefix("http"), let url = URL(string: raw),
           let data = try? Data(contentsOf: url) {
            return UIImage(data: data)
        }
        return nil
    }

    private static func loadSnippet(api: PinkhaApi, leafId: String) async -> String {
        guard let doc = try? api.getLeaf(id: leafId) else { return "" }
        return extractText(blocks: doc.blocks, limit: 240)
    }

    private static func extractText(blocks: [BlockFfi], limit: Int) -> String {
        var pieces: [String] = []
        var remaining = limit
        for block in blocks {
            guard remaining > 0 else { break }
            let raw = block.content.spansOrEmpty.map(\.content).joined()
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            pieces.append(trimmed)
            remaining -= trimmed.count
        }
        return pieces.joined(separator: " ")
    }
}
