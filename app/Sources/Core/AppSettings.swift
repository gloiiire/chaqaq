import SwiftUI
import PinkhaCore

/// User-facing preferences that affect the whole app. Persisted in
/// `UserDefaults` so they survive a relaunch — small enough that a real
/// data layer would be overkill.
///
/// Two settings today:
/// 1. `accentColorName` — drives `.tint(...)` at the root so every
///    standard SwiftUI affordance (selected tab icon, cursor, swipe
///    actions, NavigationLink chevron, etc.) recolors uniformly.
/// 2. `spotlightTinted` — when on, the search-hit spotlight paints a
///    soft accent tint behind the matched block in addition to blurring
///    the rest of the doc. Off by default; some users prefer the
///    cleaner blur-only look.
@Observable
final class AppSettings {
    /// Catalogue of accent colors offered in the picker. Keeping the
    /// mapping name → Color in one place lets us persist a stable
    /// string in UserDefaults (Color isn't `Codable` cleanly) and round-
    /// trip it on relaunch.
    /// Books.app-style reading themes — bundles a background colour
    /// and a foreground colour, plus a "bold" flavour that switches
    /// the editor's base font to a heavy weight. Default `.original`
    /// keeps the iOS-native system background, so the rest of the
    /// app stays untouched until a user opts in.
    enum Theme: String, CaseIterable, Identifiable {
        case original, tranquille, papier, gras, calme, attention

        var id: String { rawValue }

        /// Localizable via `Localizable.xcstrings` — returning a
        /// `LocalizedStringKey` ensures `Text(theme.label)` picks the
        /// `LocalizedStringKey` initializer, not the verbatim-`String`
        /// one that bypasses the catalog.
        var label: LocalizedStringKey {
            switch self {
            case .original:  return "Match App Appearance"
            case .tranquille: return "Tranquille"
            case .papier:    return "Papier"
            case .gras:      return "Gras"
            case .calme:     return "Calme"
            case .attention: return "Attention"
            }
        }

        /// Same content, already resolved through the string catalogue,
        /// for places where SwiftUI wants a `String` (text
        /// interpolation, attributed-string composition, etc.).
        var labelString: String {
            switch self {
            case .original:   return String(localized: "Match App Appearance")
            case .tranquille: return String(localized: "Tranquille")
            case .papier:     return String(localized: "Papier")
            case .gras:       return String(localized: "Gras")
            case .calme:      return String(localized: "Calme")
            case .attention:  return String(localized: "Attention")
            }
        }

        /// `nil` = inherit the system background (`.original` does
        /// this so light/dark mode keeps working untouched).
        var backgroundColor: Color? {
            switch self {
            case .original:  return nil
            // `.tranquille` is intentionally close to iOS-26's native
            // dark keyboard / `systemBackground` (≈ 0.11) so the seam
            // between the doc and the keyboard reads as one surface
            // rather than two shades of dark fighting each other.
            case .tranquille: return Color(red: 0.11, green: 0.11, blue: 0.11)
            case .papier:    return Color(red: 0.96, green: 0.96, blue: 0.96)
            case .gras:      return Color.white
            case .calme:     return Color(red: 0.93, green: 0.88, blue: 0.78)
            case .attention: return Color(red: 0.98, green: 0.95, blue: 0.86)
            }
        }

        /// Foreground colour for body text. `nil` falls back to
        /// `.label` (system-dynamic).
        var foregroundColor: Color? {
            switch self {
            case .original:  return nil
            case .tranquille: return Color(white: 0.88)
            case .papier:    return Color.black
            case .gras:      return Color.black
            case .calme:     return Color(red: 0.18, green: 0.14, blue: 0.07)
            case .attention: return Color(red: 0.18, green: 0.14, blue: 0.07)
            }
        }

        /// Forces a `ColorScheme` override on the theme's view tree
        /// so system controls (cursor, selection lozenge, etc.) match
        /// the theme background. `nil` = leave system / appearance
        /// alone. Only `.tranquille` is intrinsically dark — the
        /// other backgrounds are light.
        var colorScheme: ColorScheme? {
            switch self {
            case .original:  return nil
            case .tranquille: return .dark
            case .papier, .gras, .calme, .attention: return .light
            }
        }

        /// Whether the theme paints body text with a bolder weight
        /// (Books.app's "Gras" flavour).
        var boldText: Bool { self == .gras }
    }

    /// User-facing color scheme override — `.system` follows the
    /// device-wide setting (default), `.light` / `.dark` force a
    /// specific scheme regardless of what iOS does. Mirrors the
    /// pattern most modern apps offer in their own Appearance
    /// section instead of forcing the user out into Settings.app.
    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        /// Maps to SwiftUI's `.preferredColorScheme(_:)` — `nil` for
        /// `.system` so the view inherits whatever iOS decides.
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light:  return .light
            case .dark:   return .dark
            }
        }

        var label: LocalizedStringKey {
            switch self {
            case .system: return "System"
            case .light:  return "Light"
            case .dark:   return "Dark"
            }
        }

        var systemImage: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light:  return "sun.max"
            case .dark:   return "moon"
            }
        }
    }

    enum AccentChoice: String, CaseIterable, Identifiable {
        case pink, purple, blue, teal, green, yellow, orange, red

        var id: String { rawValue }

        var color: Color {
            switch self {
            case .pink:   return .pink
            case .purple: return .purple
            case .blue:   return .blue
            case .teal:   return .teal
            case .green:  return .green
            case .yellow: return .yellow
            case .orange: return .orange
            case .red:    return .red
            }
        }

        var label: LocalizedStringKey {
            switch self {
            case .pink:   return "Pink"
            case .purple: return "Purple"
            case .blue:   return "Blue"
            case .teal:   return "Teal"
            case .green:  return "Green"
            case .yellow: return "Yellow"
            case .orange: return "Orange"
            case .red:    return "Red"
            }
        }
    }

    private let accentKey         = "pinkha.settings.accentColor"
    private let spotlightKey      = "pinkha.settings.spotlightTinted"
    private let recentCountKey    = "pinkha.settings.recentCount"
    private let cursorAccentKey   = "pinkha.settings.cursorFollowsAccent"
    private let appearanceKey     = "pinkha.settings.appearance"
    private let themeKey          = "pinkha.settings.theme"
    /// Public so `Haptic` can read the flag without an
    /// `AppSettings` env injection — it's polled from inside the
    /// haptic generators which run in `@MainActor` static functions.
    static let hapticsKey         = "pinkha.settings.hapticsEnabled"
    /// Public so `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`
    /// can read the flag — UIKit polls that callback at every layout
    /// pass and we can't inject `AppSettings` into a plain
    /// `UIApplicationDelegate`.
    static let rotationLockKey    = "pinkha.settings.rotationLocked"

    /// When on, the text-input caret + selection highlight use the
    /// chosen accent color. Off by default (white, à la Notion) so
    /// the cursor stays quiet against most block colors.
    var cursorFollowsAccent: Bool {
        didSet {
            UserDefaults.standard.set(cursorFollowsAccent, forKey: cursorAccentKey)
        }
    }

    /// How many docs the "Recent" strip on the Notes home shows.
    /// Bounded 5–20 ; 7 is the default that fits ~2 fully-visible
    /// cards plus a peek of a third on iPhone 17 Pro.
    var recentCount: Int {
        didSet {
            let clamped = max(5, min(20, recentCount))
            if clamped != recentCount {
                recentCount = clamped
                return
            }
            UserDefaults.standard.set(recentCount, forKey: recentCountKey)
        }
    }

    var accentChoice: AccentChoice {
        didSet {
            UserDefaults.standard.set(accentChoice.rawValue, forKey: accentKey)
        }
    }

    var spotlightTinted: Bool {
        didSet {
            UserDefaults.standard.set(spotlightTinted, forKey: spotlightKey)
        }
    }

    /// Whether the global `HapticTapStyle` (and the semantic
    /// `Haptic.tap` / `Haptic.toggle` / … helpers) fire any taptic
    /// feedback. Default on — users who find the per-button buzz
    /// excessive can flip this off in Settings.
    var hapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticsEnabled, forKey: AppSettings.hapticsKey)
        }
    }

    /// When on, the app refuses to rotate into landscape — handy on
    /// iPhone where a stray wrist twist while reading flips a doc
    /// sideways. Off by default so the existing landscape layout
    /// keeps working. Toggling immediately snaps the active scene
    /// back to portrait and invalidates UIKit's supported-orientation
    /// cache.
    var rotationLocked: Bool {
        didSet {
            UserDefaults.standard.set(rotationLocked, forKey: AppSettings.rotationLockKey)
            AppSettings.applyRotationLockToScenes(locked: rotationLocked)
        }
    }

    /// Pokes UIKit so the orientation change becomes immediate, instead
    /// of waiting for the next device-motion event. `requestGeometryUpdate`
    /// performs the visible rotation ; `setNeedsUpdateOfSupportedInterfaceOrientations`
    /// invalidates the cached "which orientations does this VC accept"
    /// answer so the next query lands on our `AppDelegate` override.
    static func applyRotationLockToScenes(locked: Bool) {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let mask: UIInterfaceOrientationMask = locked ? .portrait : .allButUpsideDown
        let geometry = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        for scene in scenes {
            scene.requestGeometryUpdate(geometry) { _ in }
            scene.windows.first?.rootViewController?
                .setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    /// Books.app-style reading theme applied at the app root. Per-doc
    /// `Document.theme` overrides this when set.
    var theme: Theme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: themeKey)
        }
    }

    /// Light / dark / system override applied at the app root via
    /// `.preferredColorScheme(_:)`. Default `.system` follows iOS.
    var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: appearanceKey)
            // SwiftUI's `.preferredColorScheme(_:)` on sheets has
            // known quirks (mostly on simulator) — the sheet caches
            // the scheme on its host and `nil` doesn't always
            // release a prior forced override. Setting it on every
            // attached UIWindow via UIKit is the reliable belt-
            // and-suspenders: `.unspecified` truly lets iOS take
            // back control, `.light` / `.dark` force a scheme that
            // covers both the main app *and* any presented sheets.
            applyAppearanceToWindows()
        }
    }

    /// Walks every window of every connected scene and writes the
    /// matching `overrideUserInterfaceStyle`. Called from
    /// `appearance.didSet` and once at the end of `init()` so the
    /// stored preference is honoured at cold launch.
    func applyAppearanceToWindows() {
        let style: UIUserInterfaceStyle = switch appearance {
        case .system: .unspecified
        case .light:  .light
        case .dark:   .dark
        }
        // Short-circuit when the key window already matches — setting
        // `overrideUserInterfaceStyle` forces a layout pass on every
        // descendant. Skipping the redundant set keeps the
        // backgrounding snapshot fast.
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        if windows.first?.overrideUserInterfaceStyle == style { return }
        // Animate the override flip so the relayout fades in over
        // 0.25s instead of snapping — the actual layout cost is the
        // same, but the perceived "slowness" comes from the abrupt
        // colour swap of the entire view tree (NavStack + tabs +
        // toolbars + cover images), which UIKit handles much better
        // when wrapped in `UIView.animate`.
        UIView.animate(withDuration: 0.25) {
            windows.forEach { $0.overrideUserInterfaceStyle = style }
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: accentKey)
        // Apple-ecosystem default — sticks closer to the system blue
        // most iOS apps use unless the user picks something else.
        self.accentChoice = AccentChoice(rawValue: stored ?? "") ?? .blue
        // Default off — matches the latest preference. A user that
        // wants the tint flips the toggle in Settings.
        self.spotlightTinted = UserDefaults.standard.bool(forKey: spotlightKey)
        let storedCount = UserDefaults.standard.integer(forKey: recentCountKey)
        self.recentCount = (5...20).contains(storedCount) ? storedCount : 7
        // Default ON — selection lozenge needs the accent tint to be
        // visible. UIKit ties caret colour to selection tint on
        // UITextView, so the caret follows along. A user that
        // prefers white (Notion-style) can flip the toggle off.
        if UserDefaults.standard.object(forKey: cursorAccentKey) != nil {
            self.cursorFollowsAccent = UserDefaults.standard.bool(forKey: cursorAccentKey)
        } else {
            self.cursorFollowsAccent = true
        }
        let storedAppearance = UserDefaults.standard.string(forKey: appearanceKey)
        self.appearance = AppearanceMode(rawValue: storedAppearance ?? "") ?? .system
        let storedTheme = UserDefaults.standard.string(forKey: themeKey)
        self.theme = Theme(rawValue: storedTheme ?? "") ?? .original
        // Default ON — users discover the haptic feel and decide
        // whether they want it. Existing users without the key set
        // get the same default behaviour.
        if UserDefaults.standard.object(forKey: AppSettings.hapticsKey) != nil {
            self.hapticsEnabled = UserDefaults.standard.bool(forKey: AppSettings.hapticsKey)
        } else {
            self.hapticsEnabled = true
        }
        // Default OFF — preserves the existing landscape behaviour
        // for users who haven't touched the toggle yet.
        self.rotationLocked = UserDefaults.standard.bool(forKey: AppSettings.rotationLockKey)
    }

    var accentColor: Color { accentChoice.color }

    /// Resets every preference back to its factory default —
    /// accent = orange, spotlight tint off, recent count = 7. Used
    /// by the floating "Reset" button in `SettingsView`.
    func resetToDefaults() {
        accentChoice        = .blue
        spotlightTinted     = false
        recentCount         = 7
        cursorFollowsAccent = true
        appearance          = .system
        theme               = .original
        hapticsEnabled      = true
        rotationLocked      = false
    }
}
