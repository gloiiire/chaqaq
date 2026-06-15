import UIKit
import PinkhaCore
import PinkhaComposer

extension Notification.Name {
    /// Fired when iOS hands the app a Home Screen Quick Action
    /// (long-press the app icon). Userinfo carries the shortcut
    /// `type` under the `"type"` key, e.g. `com.gloiiire.pinkha.new-note`.
    static let pinkhaQuickAction = Notification.Name("PinkhaQuickAction")
}

/// Thin `UIApplicationDelegate` bridge — only present so we can wire a
/// custom `SceneDelegate` (which is where every quick-action callback
/// actually lives, post-iOS 13) and serve the rotation-lock override
/// that `requestGeometryUpdate` polls on every layout pass. Wired into
/// the SwiftUI app via `@UIApplicationDelegateAdaptor` so we don't have
/// to give up the `App` lifecycle.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set when the user cold-launches the app via a Home Screen Quick
    /// Action — captured by `SceneDelegate.scene(_:willConnectTo:options:)`
    /// from the modern `UIScene.ConnectionOptions.shortcutItem`. Drained
    /// by `Composer.bindQuickActions()` as soon as the scene wakes up.
    /// (The legacy `UIApplication.LaunchOptionsKey.shortcutItem` path
    /// is deprecated since iOS 13 and intentionally not used.)
    static var pendingShortcutType: String?

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

/// Owns every Home Screen Quick Action callback :
/// - **Cold launch** : `scene(_:willConnectTo:options:)` reads
///   `connectionOptions.shortcutItem` (iOS 13+ replacement of the
///   deprecated `UIApplication.LaunchOptionsKey.shortcutItem`). The
///   item is parked on `AppDelegate.pendingShortcutType` and drained
///   by `Composer.bindQuickActions()` once the SwiftUI scene is alive.
/// - **Warm launch** : `windowScene(_:performActionFor:)` posts on
///   `NotificationCenter` straight away — `Composer` is already
///   listening.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcut = connectionOptions.shortcutItem {
            AppDelegate.pendingShortcutType = shortcut.type
        }
    }

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
