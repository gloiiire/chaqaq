# Safari Tab Grid — Reverse-engineering findings (iOS 26.5.1)

Source: MobileSafari.framework + MobileSafariUI.framework extracted from
`iPhone18,1_26.5.1_23F81_Restore.ipsw` dyld_shared_cache, class-dumped with
`ipsw class-dump`. Build: iOS 26.5, SDK 26.5, Source 624.2.5.10.4.

Headers extracted to `safari_re/headers/{MobileSafari,MobileSafariUI}/`.
Demangled symbol table at `safari_re/MobileSafari_symbols.txt`.

---

## 1. Architecture map (confirmed from class-dump)

### Top of the hierarchy

```
TabSwitcherViewController (UIViewController, Obj-C wrapper)
    ↓ owns
SFTabSwitcher (UIViewController, Obj-C façade)
    ↓ has property
    panGestureRecognizer: UIPanGestureRecognizer   ← lives at switcher level
    panGestureRecognizerForTrackingPinchTranslationVelocity
    pinchGestureRecognizer
    ↓ contains
SFTabOverview (BlurrableView : UIView, UIScrollViewDelegate)
```

**Key insight #1**: the pan gesture lives on `SFTabSwitcher`, NOT on each cell.
The switcher dispatches to the right cell based on hit-testing. Our current
implementation puts a `UIPanGestureRecognizer` on every cell's `contentView`
— which is why the pan competes badly with `UIHostingConfiguration` and the
collection view's scroll pan.

### SFTabOverview owns FOUR overlay containers

From `SFTabOverview.h` (ivars):

```
$__lazy_storage_$_collectionView    ← the actual UICollectionView
closingItemsContainerView           ← cells mid-close animation live HERE
transitionContainerView             ← scene transitions (tab-overview ↔ tab)
overlayContainerView                ← misc overlays
overlayView, peekingOverlayView, backgroundView, contentBelowSearchBarView
searchBarContainerView, $__lazy_storage_$_tipView
```

Plus tracking sets:

```
itemsClosedWithGesture       ← Set<Item> currently being swipe-closed
itemsToCloseAfterCommit      ← Set<Item> queued for deletion
itemsWithHiddenThumbnail
itemsWithHiddenTitle
hiddenItems
```

**Key insight #2**: Safari's close pipeline is a 3-state machine:
1. User starts swiping → item enters `itemsClosedWithGesture`
2. Gesture commits → item moves to `itemsToCloseAfterCommit`,
   the cell is reparented to `closingItemsContainerView`
3. Snapshot apply removes the item from the data source, collection view reflows
   in parallel; the cell finishes its exit animation independently in the
   container overlay.

This decouples the cell's exit animation from the collection view's reflow.
The collection view never sees a "closing" cell — by the time the snapshot
is applied, the cell has already been removed from its hierarchy. Zero conflict.

---

## 2. The cell is NOT a UICollectionViewCell

From `SFTabOverviewItemView.h` and `_TtCC12MobileSafari11TabOverview8ItemView.h`:

```
SFTabOverviewItemView : UIView                              // not UICollectionViewCell !
    closingBackgroundView, configuration, metrics,
    thumbnailView, tintedSelectionBorderView, titleView

TabOverview.ItemView : SFFluidTabOverviewReusableView       // Safari's custom base
    closeHandler: (Item) -> ()      ← closure called when close fires
    unpinHandler: (Item) -> ()
```

`SFFluidTabOverviewReusableView` extends `SFFluidCollectionReusableView`, a
**custom recycled-view class Apple wrote from scratch**:

```
SFFluidCollectionReusableView : UIView
    reuseIdentifier: String?
    representedElement: AnyObject?
    contentView: UIView
    isSelected: Bool
    isHighlighted: Bool
```

This is a hand-rolled clone of `UICollectionReusableView` — Apple needed cells
that can leave the collection view (move into `closingItemsContainerView`)
without breaking the recycling/dequeue contract. `UICollectionView` doesn't
let you do that with its own cells.

**Key insight #3**: Safari did NOT use `UIHostingConfiguration` or any SwiftUI
embedding. The cell is a pure UIView with `thumbnailView`, `titleView`,
`tintedSelectionBorderView`, `closingBackgroundView` as direct subviews.

---

## 3. The custom layout

From `_TtCC12MobileSafari19TabOverviewSwitcher6Layout.h`:

```
TabOverviewSwitcher.Layout : SwiftObject              // NOT UICollectionViewLayout
    configuration: TabOverviewSwitcher.Configuration
    content: TabOverviewSwitcher.Content
    metrics: TabOverviewSwitcher.Metrics
    deck: Deck                                        ← stacking/transform engine
    itemTypes: [LayoutItemType]
    interactiveInsertionInfo: InteractiveInsertionInfo  ← gesture state in layout !
    interactiveInsertionStyle: InteractiveInsertionStyle
    scrollViewState: ScrollViewState
    highlightedPeekingPage, hoveredPeekingPage
```

The layout is **not even a `UICollectionViewLayout` subclass** — it's a plain
`SwiftObject`. Safari hand-rolled the entire layout pass, plugging into the
collection view via a custom path. The layout *itself* holds the active
gesture state (`interactiveInsertionInfo`), so layout attributes are derived
from gesture progress directly.

This is the opposite of our current `TabGridCollectionViewLayout` which
sub-classes `UICollectionViewCompositionalLayout` and only overrides
`finalLayoutAttributesForDisappearingItem`. Safari treats the gesture as
*part of the layout state* — every relayout reads the gesture progress.

---

## 4. The match-move animation primitive

From `_TtC12MobileSafari19MatchMoveTransition.h` and the two `*MatchMoveViewRegistration.h`:

```
MatchMoveTransition : SwiftObject
    items: [Item]                                  ← things to animate
    alongsideAnimations: [AlongsideAnimation]      ← anims that ride along
    animationSettingsProvider: (Int, Item) -> AnimationSettings
    completionHandlers: [(Bool) -> ()]
    dispatchGroup: DispatchGroup
    isValid: Bool

TabOverviewItemViewMatchMoveViewRegistration : SwiftObject
    transition: MatchMoveTransition?
    views: [TabOverviewItemView]
    willInvalidate: () -> ()
    isValid: Bool

ThumbnailMatchMoveViewRegistration : SwiftObject
    topView: TabThumbnailView
    views: [TabThumbnailView]                      ← stack of views to animate together
    alongsideAnimations: [AlongsideAnimation]
    canBeRetargeted: Bool                          ← can change destination mid-flight
    wasRetargeted: Bool
    invalidationHandlers: [(MatchMoveViewRegistration) -> ()]
    thumbnailRestingSize: CGSize?
    transition: MatchMoveTransition?
    borrowedContentOpacityAnimator: ThumbnailBorrowedContentOpacityAnimator?
    controlsVisibilityAnimator: ThumbnailControlsVisibilityAnimator?
```

**Match-move** = "given a source view's frame and a destination view's frame,
animate the source view from one to the other, while the destination view
fades in (or stays hidden until the transition lands)". It's how iOS does
the App Library → app launch transition, Photos → detail, etc.

Safari uses it for:
- Tab thumbnail → web view (when you tap a tab)
- Web view → tab thumbnail (when you enter overview)
- Reordering tabs (during interactive insertion)

The `canBeRetargeted` flag is critical: if the user starts dragging a tab
toward position A, then changes their mind toward position B, the same
in-flight transition re-targets to B instead of completing to A and starting
a new one. That's the smoothness everyone notices.

---

## 5. The interactive insertion state machine

From `_TtC12MobileSafari25InteractiveInsertionGroup.h`:

```
InteractiveInsertionGroup : SwiftObject
    state: InteractiveInsertionState
    threshold: CGFloat                              ← commit distance
    $__lazy_storage_$_feedbackGenerator: _UIStatesFeedbackGenerator
    stateDidChange: () -> ()
```

`_UIStatesFeedbackGenerator` is a private UIKit class that fires haptics
when the gesture crosses thresholds (the soft "tick" you feel mid-drag).
We use `UIImpactFeedbackGenerator(.soft)` which works but doesn't crescendo
the way Apple's does — `_UIStatesFeedbackGenerator` plays a different
feedback per state transition.

---

## 6. The pan gesture itself

From `SFScrollingPanGestureRecognizer.h`:

```
SFScrollingPanGestureRecognizer : UIPanGestureRecognizer
    - (BOOL)_shouldTryToBeginWithEvent:(id)event;   ← only public override
```

`_shouldTryToBeginWithEvent:` is a **private UIKit hook** (called by the
gesture machinery before `gestureRecognizerShouldBegin:`). It receives the
raw `UIEvent` so it can inspect the touch's relationship to the underlying
scroll view *before* a translation exists. This is how Safari decides
"horizontal drag = swipe-close, vertical drag = scroll" without needing
velocity (which is zero at gesture start).

We can't override `_shouldTryToBeginWithEvent:` (private). The closest
public equivalent is `gestureRecognizer:shouldReceiveTouch:` combined with
careful coexistence rules in `gestureRecognizer:shouldRequireFailureOf:`.

---

## 7. Why our current TabGridView likely doesn't fire the pan

Reading `app/Sources/Notes/TabGridView.swift:232-241`:

```swift
override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
    let v = pan.velocity(in: self)
    let shouldBegin = abs(v.x) > abs(v.y)
    return shouldBegin
}
```

**Bug**: at the exact frame `gestureRecognizerShouldBegin` is called, the
velocity is often **(0, 0)** — touches just started, no movement registered
yet. `abs(0) > abs(0)` is `false` ⇒ pan refuses to begin ⇒ no `.began` log.

**Compounding issue**: `UIHostingConfiguration` injects a `UIHostingController`-
backed view into `contentView`. That host view's own gesture recognizers
(SwiftUI uses them internally for taps, scrolls, etc.) compete with our pan
even though we added `.allowsHitTesting(false)` on the inner `AllDocsCard`.
`.allowsHitTesting(false)` only disables SwiftUI's hit-testing for that
subtree's *view content* — it does not unregister the host view's gesture
recognizers.

**Safari's approach** (recap): pan lives on the *switcher view*, not the
cells. It hit-tests the touch location against the grid layout to find the
target cell, then decides per-cell whether to start a close gesture. No
gesture is ever attached to a cell — the cell can be moved freely.

---

## 8. Recommended refactor for `TabGridView.swift`

Two paths, in increasing fidelity to Safari:

### Path A — minimal fix, keep current architecture

Keep `UICompositionalLayout`, `UICollectionViewCell` + `UIHostingConfiguration`,
but fix the pan:

1. **Move the pan gesture off the cell, onto the collection view**:
   - Add one `UIPanGestureRecognizer` to `collectionView`.
   - On `.began`, hit-test the touch location → find the indexPath → tag
     that cell as "active swipe target".
   - On `.changed`, apply the translation to the tagged cell only.
   - On `.ended`, decide commit/reset.

2. **Replace velocity-based `shouldBegin` with a directional check at first
   move**: don't return `false` from `shouldBegin`. Instead, track the first
   meaningful translation and cancel the gesture if it's not horizontal:

```swift
@objc private func handlePan(_ pan: UIPanGestureRecognizer) {
    let t = pan.translation(in: collectionView)
    switch pan.state {
    case .began:
        // Locate the target cell at the touch start point
        let p = pan.location(in: collectionView)
        guard let ip = collectionView.indexPathForItem(at: p),
              let cell = collectionView.cellForItem(at: ip) as? TabGridCell else {
            pan.state = .cancelled
            return
        }
        activeSwipeCell = cell
        directionLocked = false
    case .changed:
        if !directionLocked {
            // First meaningful movement decides : if vertical wins, bail
            // out and let the collection view's own pan take over.
            if abs(t.y) > abs(t.x) + 4 {
                pan.state = .cancelled
                activeSwipeCell = nil
                return
            }
            if abs(t.x) > 4 {
                directionLocked = true
            }
        }
        activeSwipeCell?.transform =
            CGAffineTransform(translationX: min(t.x, 0), y: 0)
    case .ended, .cancelled:
        // ... commit/reset decision unchanged ...
    default: break
    }
}
```

3. **`shouldRecognizeSimultaneouslyWith` returns `true`** so the collection
   view scroll pan and our close pan can coexist (cell pan locks horizontal,
   scroll pan handles vertical).

### Path B — Safari-fidelity, deeper refactor

Adopt the **closing container overlay** pattern:

1. Add a transparent `UIView closingItemsContainerView` as a sibling of
   the collection view in `TabGridViewController.view`, on top.

2. When a swipe commits to close:

```swift
private func closeCell(_ cell: TabGridCell, id: String) {
    // (a) Snapshot the cell's current frame in the container view's space
    let frame = cell.convert(cell.bounds, to: closingItemsContainerView)
    
    // (b) Capture a visual replica (UIView snapshot of the cell)
    guard let replica = cell.snapshotView(afterScreenUpdates: false) else { return }
    replica.frame = frame
    closingItemsContainerView.addSubview(replica)
    
    // (c) Immediately remove the model item so the collection view reflows
    items.removeAll { $0.id == id }
    var snap = NSDiffableDataSourceSnapshot<Int, String>()
    snap.appendSections([0])
    snap.appendItems(items.map(\.id), toSection: 0)
    dataSource.apply(snap, animatingDifferences: true)
    
    // (d) Animate the replica off-screen in the overlay container
    //     — completely decoupled from the collection view's reflow
    UIView.animate(withDuration: 0.28,
                   delay: 0,
                   options: [.curveEaseOut],
                   animations: {
        replica.transform = CGAffineTransform(translationX: -self.view.bounds.width * 1.3, y: 0)
        replica.alpha = 0
    }, completion: { _ in
        replica.removeFromSuperview()
    })
    
    // (e) Fire the model callback
    onClose?(id)
}
```

The genius: the collection view reflows *immediately* and *cleanly* because
the cell it just deleted was never in a weird mid-animation state — only
a visual replica (a UIView snapshot) is animating in the overlay. The
collection view's `finalLayoutAttributesForDisappearingItem` returns the
default fade-out (which is invisible because the cell was already at the
edge), and the cells around the deleted slot flow into place via the
collection view's standard animation.

3. **Remove `finalLayoutAttributesForDisappearingItem` overrides** — they're
   no longer needed once the closing animation happens in the overlay.

4. **`UIHostingConfiguration` continues to work** because we're not fighting
   it for touch handling anymore — the pan is on the collection view.

### Path B+ — optional but high-impact

5. **`_UIStatesFeedbackGenerator` substitute**: chain multiple
   `UIImpactFeedbackGenerator`s with different intensities as the swipe
   progresses past 25%, 50%, 75% of the threshold, to mimic Safari's
   crescendo haptic:

```swift
private var lastHapticZone = 0
private func updateHaptic(progress: CGFloat) {
    let zone = min(3, Int(abs(progress) / 0.25))
    if zone > lastHapticZone {
        let intensity: CGFloat = [0.3, 0.5, 0.7, 1.0][zone]
        let gen = UIImpactFeedbackGenerator(style: .soft)
        gen.impactOccurred(intensity: intensity)
        lastHapticZone = zone
    }
}
```

---

## 9. Don't bother re-implementing

- Custom `SFFluidCollectionReusableView` — `UICollectionViewCell` is fine
  for our scale (tens of cards, not hundreds of tabs)
- Custom `Layout` from scratch — `UICompositionalLayout` covers our needs
  once the close pipeline doesn't fight it
- Match-move with `canBeRetargeted` — only matters for reorder, which
  we don't have yet
- `Deck` (stacking transforms) — a Safari-specific aesthetic for the
  z-stacked tabs, not what we want for a documents grid

---

## 10. Next investigations (if needed)

To go further on the gesture details, we'd need either:

1. **Disassembly of MobileSafari** — `safari_re/dsc_extracts/MobileSafari`
   (8.6 MB) opens in Hopper or Ghidra. Search for the Swift-mangled symbol
   of `TabOverviewSwitcher.Layout` methods: the actual interactive insertion
   math lives there.

2. **`frida-trace` on a real device or simulator iOS 26**:

```bash
frida-trace -U \
    -m "-[SFTabOverview *]" \
    -m "-[SFTabOverviewItemView *]" \
    -m "-[SFTabSwitcher didReceivePanGesture:]" \
    MobileSafari
```

   This will print the exact sequence of Obj-C methods called during a real
   swipe-close, far faster than reading disassembly.

3. **Cross-reference WebKit-open-source equivalents**: Safari shares some
   private collection-view code with `UIKit`'s `_UIFluidCollectionView`
   internals (see private headers for `_UIFluid*` classes).

---

## File index

Extracted artifacts under `safari_re/`:

```
safari_re/
├── headers/
│   ├── MobileSafari/MobileSafari/       (1500+ .h files)
│   │   ├── SFTabOverview.h              ← grid root view
│   │   ├── SFTabOverviewItemView.h      ← cell
│   │   ├── SFTabSwitcher.h              ← switcher VC façade
│   │   ├── SFTabOverviewDisplayItem.h   ← scene display item
│   │   ├── SFScrollingPanGestureRecognizer.h
│   │   └── _TtC12MobileSafari19MatchMoveTransition.h
│   │   └── _TtC12MobileSafari25InteractiveInsertionGroup.h
│   │   └── _TtC12MobileSafari29SFFluidCollectionReusableView.h
│   │   └── _TtCC12MobileSafari19TabOverviewSwitcher6Layout.h
│   └── MobileSafariUI/MobileSafariUI/   (634 .h files)
│       ├── TabSwitcherViewController.h  ← Obj-C wrapper VC
│       └── TabCollection*.h             ← protocols
├── dsc_extracts/
│   └── MobileSafari                     ← 8.6 MB Swift dylib for disassembly
└── MobileSafari_symbols.txt             ← 26k demangled symbols
```
