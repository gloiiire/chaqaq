import Foundation
import PinkhaComposer

// `bindQuickActions()` lives here in the app target — not in the
// PinkhaComposer package — because it has to read
// `AppDelegate.pendingShortcutType`. AppDelegate has to stay
// app-target-side since it's the `@UIApplicationDelegateAdaptor` of
// the `@main` SwiftUI app and depends on UIKit Scene wiring that
// SwiftPM packages can't carry. Routing the dependency the other way
// would mean publicly exposing AppDelegate-the-class from the
// package, which would force the package to depend back on the app.

extension Composer {
    /// Wires Home Screen Quick Actions (long-press the app icon) into
    /// the composer. Call once on app start — covers both the cold
    /// launch path (a shortcut tap that woke the app from suspended,
    /// captured by `AppDelegate.pendingShortcutType`) and the warm
    /// launch path (Scene-delegate notification while the app is
    /// already in memory).
    func bindQuickActions() {
        // Drain any shortcut captured during cold launch.
        if let type = AppDelegate.pendingShortcutType {
            AppDelegate.pendingShortcutType = nil
            handle(shortcutType: type)
        }
        NotificationCenter.default.addObserver(
            forName: .pinkhaQuickAction,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let type = note.userInfo?["type"] as? String else { return }
            Task { @MainActor in self?.handle(shortcutType: type) }
        }
    }

    private func handle(shortcutType type: String) {
        switch type {
        case "com.gloiiire.pinkha.new-note":
            openNewLeaf()
        default:
            break
        }
    }
}
