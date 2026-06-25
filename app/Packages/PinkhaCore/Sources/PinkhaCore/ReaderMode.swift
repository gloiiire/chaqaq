import SwiftUI
import UIKit

/// Cross-cutting state for the "reader / focus" mode that hides every
/// interactive chrome element so the user can just read a leaf.
///
/// Owned at the app root and injected via `@Environment`. Views observe
/// `isActive` to know whether to render their toolbar / accessory / etc.
/// Toggling fires a soft haptic so the user knows the gesture (long-press
/// or eyeglasses tap) was registered even when the visual change is subtle.
@MainActor
@Observable
public final class ReaderMode {
    public var isActive: Bool = false

    public init() {}

    /// Flips reader mode on / off with a haptic cue.
    public func toggle() {
        isActive.toggle()
        Haptic.soft()
    }

    /// Forces reader mode off — used by the floating exit button so a
    /// repeated tap doesn't accidentally re-enter the mode.
    public func deactivate() {
        guard isActive else { return }
        isActive = false
        Haptic.soft()
    }
}

// MARK: - Multi-finger long-press gesture bridge
//
// SwiftUI's `LongPressGesture` doesn't expose `numberOfTouchesRequired`,
// so multi-finger long-press has to go through a UIKit recogniser. We
// wrap a transparent `UIView` with a `UILongPressGestureRecognizer`
// configured for N simultaneous touches; on `.began`, we call the SwiftUI
// closure once.
//
// Placed in PinkhaCore because the gesture is a cross-cutting UX
// affordance — used by the reader mode today, free to be reused for
// other shortcuts tomorrow.

public extension View {
    /// Triggers `perform` when the user holds `fingerCount` fingers down
    /// for ~0.5s anywhere on the receiver. No-op when `enabled == false`.
    /// The gesture coexists with regular taps/scrolls because the
    /// recogniser is added to a transparent overlay that defaults to
    /// `cancelsTouchesInView = false` — touches still propagate to the
    /// underlying SwiftUI view.
    func multiFingerLongPress(
        enabled: Bool,
        fingerCount: Int,
        perform: @escaping () -> Void
    ) -> some View {
        overlay(
            MultiFingerLongPressView(
                enabled: enabled,
                fingerCount: fingerCount,
                perform: perform
            )
            // `.allowsHitTesting(false)` would defeat the purpose — we
            // *need* the overlay to receive touches so its recogniser
            // can evaluate them. Touches still cascade to the underlying
            // SwiftUI views because the recogniser leaves
            // `cancelsTouchesInView` at false.
        )
    }
}

private struct MultiFingerLongPressView: UIViewRepresentable {
    let enabled: Bool
    let fingerCount: Int
    let perform: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(perform: perform) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recogniser = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        recogniser.numberOfTouchesRequired = max(2, min(3, fingerCount))
        recogniser.minimumPressDuration = 0.5
        // Let underlying SwiftUI views receive the touches too —
        // otherwise a long-press for the reader gesture would eat a
        // text-selection long-press inside the editor.
        recogniser.cancelsTouchesInView = false
        recogniser.delaysTouchesBegan = false
        recogniser.delaysTouchesEnded = false
        recogniser.isEnabled = enabled
        view.addGestureRecognizer(recogniser)
        context.coordinator.recogniser = recogniser
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.perform = perform
        context.coordinator.recogniser?.isEnabled = enabled
        context.coordinator.recogniser?.numberOfTouchesRequired = max(2, min(3, fingerCount))
    }

    @MainActor
    final class Coordinator {
        var perform: () -> Void
        weak var recogniser: UILongPressGestureRecognizer?

        init(perform: @escaping () -> Void) { self.perform = perform }

        @objc func handle(_ sender: UILongPressGestureRecognizer) {
            // Fire on `.began` only — the recogniser stays alive
            // through `.changed`/`.ended` while the user keeps holding,
            // but we want a single toggle per press.
            guard sender.state == .began else { return }
            perform()
        }
    }
}
