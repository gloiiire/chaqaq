import UIKit

// ── Haptic feedback ──────────────────────────────────────────────────────────
//
// Tiny wrapper around `UIImpactFeedbackGenerator` /
// `UINotificationFeedbackGenerator` so call sites pick *what kind of
// interaction* fired the haptic (`.tap`, `.toggle`, `.success`, …)
// instead of guessing an `UIImpactFeedbackStyle`. Naming follows the
// pattern Apple's own apps use — Music's row taps map to `.tap`,
// Mail's archive swipe maps to `.success`.
//
// Generators are heavy to create (each one warms its Taptic engine
// channel), so we keep them around in a small singleton. Calling
// `.prepare()` before each tap is cheap and noticeably tightens the
// latency — the engine doesn't have to spin up when the tap fires.

public enum Haptic {
    /// UserDefaults key for the haptics toggle. Mirrored in
    /// `AppSettings.hapticsKey` (kept in app/Sources/Core for now) —
    /// keeping both pointing at the same literal lets Haptic stay
    /// independent of AppSettings while the SettingsView toggle still
    /// writes through to the same UserDefaults slot.
    public static let hapticsKey = "pinkha.settings.hapticsEnabled"

    /// User preference gate — read once per call from UserDefaults so
    /// the setting can be flipped from the SettingsView without any
    /// observer wiring. `true` by default for users who haven't
    /// touched the toggle yet.
    @MainActor
    private static var enabled: Bool {
        // `object(forKey:)` returns nil for missing keys, otherwise
        // a boxed Bool. We treat "missing" as on.
        let stored = UserDefaults.standard.object(forKey: hapticsKey)
        return (stored as? Bool) ?? true
    }

    /// Quick selection tap — list rows, menu items, picker entries.
    /// The `UISelectionFeedbackGenerator` Apple calls "the wheel
    /// click" — light, quick, no body.
    @MainActor
    public static func tap() {
        guard enabled else { return }
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    /// Toggle / state change — lock flipped, edit mode toggled, view
    /// switched. A medium impact so the user feels "something shifted"
    /// instead of just "I tapped".
    @MainActor
    public static func toggle() {
        guard enabled else { return }
        mediumImpact.impactOccurred()
        mediumImpact.prepare()
    }

    /// Soft tap for inline auto-actions that aren't user-initiated
    /// but still want acknowledgement (auto-embed conversion, link
    /// auto-detect, etc.). Same intensity as `tap` but routed via
    /// `UIImpactFeedbackGenerator(.light)` so it doesn't compete
    /// with selection feedback during typing.
    @MainActor
    public static func soft() {
        guard enabled else { return }
        lightImpact.impactOccurred()
        lightImpact.prepare()
    }

    /// Positive completion — convert-to-embed succeeded, search hit
    /// opened, etc. Bright two-stage buzz.
    @MainActor
    public static func success() {
        guard enabled else { return }
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

    /// Destructive confirmation — delete a doc / block / book.
    /// Heavier rumble so the user feels the weight of the action.
    @MainActor
    public static func warning() {
        guard enabled else { return }
        notificationGenerator.notificationOccurred(.warning)
        notificationGenerator.prepare()
    }

    // ── Cached generators ────────────────────────────────────────────────

    @MainActor
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    @MainActor
    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    @MainActor
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    @MainActor
    private static let notificationGenerator = UINotificationFeedbackGenerator()
}

import SwiftUI

/// Default `ButtonStyle` for the whole app — fires `Haptic.tap()` the
/// moment SwiftUI registers the tap (transition from `isPressed = true`
/// back to `false`). Applied once at the app root via
/// `.buttonStyle(HapticTapStyle())`; every `Button` in the hierarchy
/// inherits it unless a child view sets a different style explicitly
/// (e.g. `.plain` in some menu rows). Visual side effects are kept
/// to the system default — we don't repaint, we just buzz.
public struct HapticTapStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            Haptic.tap()
            configuration.trigger()
        } label: {
            configuration.label
        }
    }
}
