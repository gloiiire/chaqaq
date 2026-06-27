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

    /// Effective color scheme of the currently-open leaf when it
    /// overrides the global appearance via its Books-style theme.
    /// `nil` means "no leaf is forcing a scheme right now" — root tabs
    /// or a leaf in `.original` theme. Read by `ContentView` so it can
    /// apply `.preferredColorScheme` to the whole TabView (and thus
    /// the bottom accessory bar's icons, which sit in the parent's
    /// SwiftUI environment and otherwise miss the leaf's per-doc
    /// `.preferredColorScheme` override).
    ///
    /// Set from `LeafView.onAppear` / `onChange` / `onDisappear`.
    public var activeLeafColorScheme: ColorScheme? = nil

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

public extension UITraitCollection {
    /// The device's actual `userInterfaceStyle` — read from the
    /// `UIScreen`'s trait collection, which reflects the iOS
    /// Settings → Display & Brightness appearance and IGNORES any
    /// `overrideUserInterfaceStyle` the app may have set on its
    /// windows (e.g. `AppSettings.appearance == .dark` while the
    /// device is in light mode).
    ///
    /// Use this when "match device" semantically means "follow the
    /// OS preference, not the app preference". Distinct from
    /// `UITraitCollection.current.userInterfaceStyle`, which returns
    /// the override-aware value (correct for window-scoped styling
    /// but wrong for the "Match Device" reader-appearance choice).
    @MainActor
    static var deviceUserInterfaceStyle: UIUserInterfaceStyle {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        return scene?.screen.traitCollection.userInterfaceStyle ?? .unspecified
    }
}

// MARK: - Multi-finger long-press gesture bridge
//
// SwiftUI's `LongPressGesture` doesn't expose `numberOfTouchesRequired`,
// so multi-finger long-press has to go through a UIKit recogniser.
//
// **Why the recognizer lives on the UIWindow, not a SwiftUI overlay :**
// an `.overlay { UIView }` UIView intercepts hit-testing for every
// underlying SwiftUI view — buttons, scrolls, taps all stop working
// because UIKit asks the overlay (on top) first and the overlay claims
// the touch. `cancelsTouchesInView = false` only matters once the
// recogniser is processing ; it doesn't redirect the initial hit-test.
//
// Window-level recognizers, on the other hand, see every touch in the
// app *without* participating in hit-testing — they sit alongside the
// view-tree dispatch, not on top of it. That's the textbook UIKit
// pattern for app-wide shortcuts.

public extension View {
    /// Triggers `perform` when the user holds `fingerCount` fingers down
    /// for ~0.5s anywhere on the screen. No-op when `enabled == false`.
    /// Installed at the UIWindow level so it never interferes with the
    /// hit-testing of underlying SwiftUI controls.
    func multiFingerLongPress(
        enabled: Bool,
        fingerCount: Int,
        perform: @escaping () -> Void
    ) -> some View {
        background(
            WindowGestureInstaller(
                enabled: enabled,
                fingerCount: fingerCount,
                perform: perform
            )
            // Zero-sized — we only need a UIViewRepresentable handle so
            // we can observe `didMoveToWindow` and install our recognizer
            // on the resolved UIWindow. The view itself draws nothing.
            .frame(width: 0, height: 0)
        )
    }
}

private struct WindowGestureInstaller: UIViewRepresentable {
    let enabled: Bool
    let fingerCount: Int
    let perform: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(perform: perform) }

    func makeUIView(context: Context) -> WindowAttachableView {
        let view = WindowAttachableView()
        view.coordinator = context.coordinator
        view.requestedFingerCount = max(2, min(3, fingerCount))
        view.requestedEnabled = enabled
        return view
    }

    func updateUIView(_ uiView: WindowAttachableView, context: Context) {
        context.coordinator.perform = perform
        uiView.requestedFingerCount = max(2, min(3, fingerCount))
        uiView.requestedEnabled = enabled
        uiView.refreshRecognizer()
    }

    @MainActor
    final class Coordinator {
        var perform: () -> Void
        init(perform: @escaping () -> Void) { self.perform = perform }

        @objc func handle(_ sender: UILongPressGestureRecognizer) {
            // Fire on `.began` only — the recognizer stays alive
            // through `.changed`/`.ended` while the user keeps
            // holding ; we want a single toggle per press.
            guard sender.state == .began else { return }
            perform()
        }
    }
}

/// A zero-sized UIView whose only job is to grab its hosting UIWindow
/// and install / remove a window-level long-press recogniser when its
/// settings change or it moves between windows (sheet present, scene
/// reconnect, …).
private final class WindowAttachableView: UIView {
    weak var coordinator: WindowGestureInstaller.Coordinator?
    var requestedFingerCount: Int = 2
    var requestedEnabled: Bool = true
    private weak var recognizer: UILongPressGestureRecognizer?
    private weak var attachedWindow: UIWindow?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Detach from the previous window (if any) before attaching to
        // the new one — otherwise we'd leak the recognizer in scene
        // transitions.
        detachRecognizer()
        guard window != nil else { return }
        installRecognizer()
    }

    func refreshRecognizer() {
        // Settings changed — rebuild the recognizer with the new
        // touch count / enabled flag. `numberOfTouchesRequired` is
        // not live-mutable in a way that's reliable across iOS
        // versions, so we recreate to be safe.
        detachRecognizer()
        installRecognizer()
    }

    private func installRecognizer() {
        guard let window, let coordinator else { return }
        let recogniser = UILongPressGestureRecognizer(
            target: coordinator,
            action: #selector(WindowGestureInstaller.Coordinator.handle(_:))
        )
        recogniser.numberOfTouchesRequired = requestedFingerCount
        recogniser.minimumPressDuration = 0.5
        // Critical : never cancel the underlying touches. Without this,
        // a long-press near a Button area would swallow the tap.
        recogniser.cancelsTouchesInView = false
        recogniser.delaysTouchesBegan = false
        recogniser.delaysTouchesEnded = false
        recogniser.isEnabled = requestedEnabled
        window.addGestureRecognizer(recogniser)
        self.recognizer = recogniser
        self.attachedWindow = window
    }

    private func detachRecognizer() {
        if let recognizer, let attachedWindow {
            attachedWindow.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
        attachedWindow = nil
    }

    deinit {
        // On main actor because the recognizer add/remove API is
        // implicitly MainActor in modern UIKit ; the view is owned
        // by the SwiftUI render thread which runs on main.
        MainActor.assumeIsolated { detachRecognizer() }
    }
}
