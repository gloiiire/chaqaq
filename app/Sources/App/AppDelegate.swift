import UIKit

extension Notification.Name {
    /// Fired when iOS hands the app a Home Screen Quick Action
    /// (long-press the app icon). Userinfo carries the shortcut
    /// `type` under the `"type"` key, e.g. `com.gloiiire.pinkha.new-note`.
    static let pinkhaQuickAction = Notification.Name("PinkhaQuickAction")
}

/// Thin `UIApplicationDelegate` bridge that catches the Home Screen
/// Quick Action and forwards it through `NotificationCenter`. Wired
/// into the SwiftUI app via `@UIApplicationDelegateAdaptor` so we don't
/// have to give up the `App` lifecycle. The `Composer` listens on the
/// other end and drives the matching creation flow.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set on cold launch when the user taps a Quick Action while the
    /// app was suspended. `Composer.bindQuickActions()` consumes it as
    /// soon as the scene wakes up.
    static var pendingShortcutType: String?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if let shortcut = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            AppDelegate.pendingShortcutType = shortcut.type
        }
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    /// UIKit calls this on every layout pass to decide which
    /// orientations the window may rotate into. We read the persisted
    /// flag straight from `UserDefaults` instead of holding an
    /// `AppSettings` reference — the delegate is a singleton owned
    /// by UIKit, not by the SwiftUI scene. `.portrait` when locked,
    /// `.allButUpsideDown` otherwise (matches the Info.plist set).
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        let locked = UserDefaults.standard.bool(forKey: AppSettings.rotationLockKey)
        return locked ? .portrait : .allButUpsideDown
    }
}

/// Catches the shortcut when the app is already running (warm launch).
/// Cold launches go through `AppDelegate.application(_:didFinishLaunching…)`
/// instead and store the shortcut on the static property.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        NotificationCenter.default.post(
            name: .pinkhaQuickAction,
            object: nil,
            userInfo: ["type": shortcutItem.type]
        )
        completionHandler(true)
    }
}
