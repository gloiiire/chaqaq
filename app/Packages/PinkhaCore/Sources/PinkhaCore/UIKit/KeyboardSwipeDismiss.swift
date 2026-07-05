import UIKit

// ── Global keyboard swipe-to-dismiss ──────────────────────────────────────────
//
// `.scrollDismissesKeyboard(.interactively)` only fires when the scroll
// view actually scrolls. Sheets with a short Form fit on one screen,
// so there's no scroll, so swiping down does nothing — the user is
// stuck tapping the small "down arrow" key. This installs a fall-back
// pan recognizer on the key window that detects a strong downward
// flick anywhere in the app and dismisses the first responder, while
// staying out of the way of every other gesture.

/// One-shot installer for a window-level pan recognizer that
/// resigns the first responder on a strong downward swipe. Wired
/// from `PinkhaApp.body` via `.onAppear` so it's installed once
/// the SwiftUI window exists.
public final class GlobalKeyboardDismissPan: NSObject, UIGestureRecognizerDelegate {
    public static let shared = GlobalKeyboardDismissPan()

    /// Tracks installation per UIWindow — multiple scenes (iPad
    /// multitasking, external display) each get their own
    /// recognizer without re-installing on the same window.
    private var installedWindows: Set<ObjectIdentifier> = []

    /// Idempotent. Call from `.onAppear` on the root view ; also
    /// re-arms an observer that catches windows created later (the
    /// SwiftUI sheet container in iOS 26 spins up a new
    /// `UIWindow`, so the initial sweep would miss it otherwise).
    public func installIfNeeded() {
        sweep()
        NotificationCenter.default.removeObserver(
            self, name: UIWindow.didBecomeVisibleNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sweep),
            name: UIWindow.didBecomeVisibleNotification, object: nil)
    }

    @objc private func sweep() {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for window in ws.windows {
                attach(to: window)
            }
        }
    }

    private func attach(to window: UIWindow) {
        let key = ObjectIdentifier(window)
        guard !installedWindows.contains(key) else { return }
        // Skip system input windows — the keyboard hosts its own
        // gesture machinery that we must not duplicate.
        let typeName = String(describing: type(of: window))
        if typeName.contains("UITextEffectsWindow")
            || typeName.contains("UIRemoteKeyboardWindow") { return }
        let pan = UIPanGestureRecognizer(
            target: self, action: #selector(handle(_:)))
        pan.delegate = self
        // Critical : don't swallow taps / scrolls / native
        // keyboard accessory clicks. We only observe.
        pan.cancelsTouchesInView = false
        window.addGestureRecognizer(pan)

        // Tap fall-back : a tap that lands on a non-editable view
        // also ends editing. `shouldReceive(touch:)` filters out
        // taps on text inputs so the user can still focus a
        // sibling field without first losing focus.
        let tap = UITapGestureRecognizer(
            target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        window.addGestureRecognizer(tap)

        installedWindows.insert(key)
    }

    @objc private func handle(_ pan: UIPanGestureRecognizer) {
        // Velocity is more reliable than translation here : a quick
        // flick down should dismiss even if the finger barely moved
        // 30 pt, and a slow horizontal drag should never trigger.
        guard pan.state == .changed else { return }
        let v = pan.velocity(in: nil)
        if v.y > 700 && abs(v.x) < 400 {
            // The recognizer is installed on the window, so `pan.view`
            // IS the window — `endEditing` resolves the first responder
            // directly instead of broadcasting a selector up the
            // responder chain via `sendAction`.
            pan.view?.endEditing(true)
        }
    }

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended else { return }
        tap.view?.endEditing(true)
    }

    // ── UIGestureRecognizerDelegate ──────────────────────────────

    /// Fire alongside scroll views / lists / SwiftUI gesture
    /// machinery so our observer doesn't compete with theirs.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    /// Ignore touches that started inside the keyboard window —
    /// the system handles those, and our recognizer would otherwise
    /// fight the keyboard's own internal gestures (next-word
    /// pickers, predictive bar).
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        if let touchedWindow = touch.view?.window {
            // The keyboard lives in a UITextEffectsWindow ;
            // resigning from there would just hide the keyboard
            // via the system shortcut anyway, but skipping the
            // input window keeps the accessory bar's own pan
            // gestures intact.
            let typeName = String(describing: type(of: touchedWindow))
            if typeName.contains("UITextEffectsWindow")
                || typeName.contains("UIRemoteKeyboardWindow") {
                return false
            }
        }
        // Never observe touches inside a UIAlertController. Alerts
        // manage their own keyboard (TextField prompts like "New
        // Shelf") and their action "buttons" are private views —
        // neither UIControl nor UITextInput — so the generic filters
        // below let the tap through. Firing resignFirstResponder
        // there dismisses the keyboard mid-press, the alert
        // re-centers, and the user's tap on Cancel / Create is lost
        // — they have to tap twice.
        if Self.touchIsInsideAlert(touch) { return false }
        // Tap-only filter : never fire when the touch landed on a
        // text input, otherwise tapping a sibling TextField would
        // first dismiss the keyboard instead of moving focus.
        if gestureRecognizer is UITapGestureRecognizer {
            return !Self.touchIsOnTextInput(touch)
        }
        return true
    }

    /// Walks the touched view's superview chain looking for any view
    /// vended by UIAlertController (`_UIAlertControllerView`,
    /// `_UIAlertControllerActionView`, …). The type-name match keeps
    /// us off private API while reliably identifying the alert subtree.
    private static func touchIsInsideAlert(_ touch: UITouch) -> Bool {
        var view: UIView? = touch.view
        while let v = view {
            if String(describing: type(of: v)).contains("AlertController") {
                return true
            }
            view = v.superview
        }
        return false
    }

    /// Walks the touched view's hierarchy looking for a UIKit
    /// text-input ancestor (UITextField / UITextView and their
    /// SwiftUI-backed wrappers). Used to decide whether a tap
    /// should dismiss the keyboard.
    private static func touchIsOnTextInput(_ touch: UITouch) -> Bool {
        var view: UIView? = touch.view
        while let v = view {
            if v is UITextInput { return true }
            if v is UIControl { return false } // buttons, switches, etc.
            view = v.superview
        }
        return false
    }
}
