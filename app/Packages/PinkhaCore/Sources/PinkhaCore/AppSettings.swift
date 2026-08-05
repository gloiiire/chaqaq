import SwiftUI

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
@MainActor
@Observable
public final class AppSettings {
    /// Catalogue of accent colors offered in the picker. Keeping the
    /// mapping name → Color in one place lets us persist a stable
    /// string in UserDefaults (Color isn't `Codable` cleanly) and round-
    /// trip it on relaunch.
    /// Books.app-style reading themes — bundles a background colour
    /// and a foreground colour, plus a "bold" flavour that switches
    /// the editor's base font to a heavy weight. Default `.original`
    /// keeps the iOS-native system background, so the rest of the
    /// app stays untouched until a user opts in.
    public enum Theme: String, CaseIterable, Identifiable {
        case original, tranquille, papier, gras, calme, attention

        public var id: String { rawValue }

        /// Localizable via `Localizable.xcstrings` — returning a
        /// `LocalizedStringKey` ensures `Text(theme.label)` picks the
        /// `LocalizedStringKey` initializer, not the verbatim-`String`
        /// one that bypasses the catalog.
        public var label: LocalizedStringKey {
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
        public var labelString: String {
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
        public var backgroundColor: Color? {
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
        public var foregroundColor: Color? {
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
        public var colorScheme: ColorScheme? {
            switch self {
            case .original:  return nil
            case .tranquille: return .dark
            case .papier, .gras, .calme, .attention: return .light
            }
        }

        /// Whether the theme paints body text with a bolder weight
        /// (Books.app's "Gras" flavour).
        public var boldText: Bool { self == .gras }
    }

    /// User-facing color scheme override — `.system` follows the
    /// device-wide setting (default), `.light` / `.dark` force a
    /// specific scheme regardless of what iOS does. Mirrors the
    /// pattern most modern apps offer in their own Appearance
    /// section instead of forcing the user out into Settings.app.
    public enum AppearanceMode: String, CaseIterable, Identifiable {
        case system, light, dark

        public var id: String { rawValue }

        /// Maps to SwiftUI's `.preferredColorScheme(_:)` — `nil` for
        /// `.system` so the view inherits whatever iOS decides.
        public var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light:  return .light
            case .dark:   return .dark
            }
        }

        public var label: LocalizedStringKey {
            switch self {
            case .system: return "System"
            case .light:  return "Light"
            case .dark:   return "Dark"
            }
        }

        public var systemImage: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light:  return "sun.max"
            case .dark:   return "moon"
            }
        }
    }

    public enum AccentChoice: String, CaseIterable, Identifiable {
        case pink, purple, blue, teal, green, yellow, orange, red

        public var id: String { rawValue }

        public var color: Color {
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

        public var label: LocalizedStringKey {
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
    private let readerLongPressEnabledKey  = "pinkha.settings.readerLongPressEnabled"
    private let readerFingerCountKey       = "pinkha.settings.readerLongPressFingerCount"
    private let readerHidesStatusBarKey    = "pinkha.settings.readerHidesStatusBar"
    private let hidesAccessoryOffRootKey   = "pinkha.settings.hidesAccessoryOutsideLibraryRoot"
    /// Public so `Haptic` can read the flag without an
    /// `AppSettings` env injection — it's polled from inside the
    /// haptic generators which run in `@MainActor` static functions.
    public static let hapticsKey         = "pinkha.settings.hapticsEnabled"
    /// Public so `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`
    /// can read the flag — UIKit polls that callback at every layout
    /// pass and we can't inject `AppSettings` into a plain
    /// `UIApplicationDelegate`.
    public static let rotationLockKey    = "pinkha.settings.rotationLocked"
    private let linkPreviewsKey          = "pinkha.settings.linkPreviewsEnabled"

    /// When on, the text-input caret + selection highlight use the
    /// chosen accent color. Off by default (white, à la Notion) so
    /// the cursor stays quiet against most block colors.
    public var cursorFollowsAccent: Bool {
        didSet {
            UserDefaults.standard.set(cursorFollowsAccent, forKey: cursorAccentKey)
        }
    }

    /// How many docs the "Recent" strip on the Library home shows.
    /// Bounded 5–20 ; 7 is the default that fits ~2 fully-visible
    /// cards plus a peek of a third on iPhone 17 Pro.
    public var recentCount: Int {
        didSet {
            let clamped = max(5, min(20, recentCount))
            if clamped != recentCount {
                recentCount = clamped
                return
            }
            UserDefaults.standard.set(recentCount, forKey: recentCountKey)
        }
    }

    public var accentChoice: AccentChoice {
        didSet {
            UserDefaults.standard.set(accentChoice.rawValue, forKey: accentKey)
        }
    }

    public var spotlightTinted: Bool {
        didSet {
            UserDefaults.standard.set(spotlightTinted, forKey: spotlightKey)
        }
    }

    /// Whether the global `HapticTapStyle` (and the semantic
    /// `Haptic.tap` / `Haptic.toggle` / … helpers) fire any taptic
    /// feedback. Default on — users who find the per-button buzz
    /// excessive can flip this off in Settings.
    public var hapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticsEnabled, forKey: AppSettings.hapticsKey)
        }
    }

    /// Whether Embed blocks fetch a preview (OpenGraph title, image,
    /// favicon) when a leaf is rendered.
    ///
    /// Default on — the card is the point of the block. Off makes leaf
    /// rendering fully offline: an embed then shows its host and
    /// nothing else. That matters because the fetch is *automatic* —
    /// scrolling past a link is enough to tell its server that this
    /// device opened the note containing it, which is not something
    /// every user wants a private notes app doing on their behalf.
    public var linkPreviewsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(linkPreviewsEnabled, forKey: linkPreviewsKey)
        }
    }

    /// When on, the app refuses to rotate into landscape — handy on
    /// iPhone where a stray wrist twist while reading flips a doc
    /// sideways. Off by default so the existing landscape layout
    /// keeps working. Toggling immediately snaps the active scene
    /// back to portrait and invalidates UIKit's supported-orientation
    /// cache.
    public var rotationLocked: Bool {
        didSet {
            UserDefaults.standard.set(rotationLocked, forKey: AppSettings.rotationLockKey)
            AppSettings.applyRotationLockToScenes(locked: rotationLocked)
        }
    }

    /// Whether the multi-finger long-press gesture toggles reader mode.
    /// Default on — power users who find the gesture intrusive can flip
    /// it off; the eyeglasses entry in the CreateBubble's overflow menu
    /// and the floating exit button stay available either way.
    public var readerLongPressEnabled: Bool {
        didSet {
            UserDefaults.standard.set(readerLongPressEnabled, forKey: readerLongPressEnabledKey)
        }
    }

    /// How many simultaneous touches trigger the reader-mode long-press.
    /// Constrained to 2 or 3 — fewer races with single-finger taps,
    /// more is uncomfortable to perform on iPhone. Default 2.
    public var readerLongPressFingerCount: Int {
        didSet {
            let clamped = max(2, min(3, readerLongPressFingerCount))
            if clamped != readerLongPressFingerCount {
                readerLongPressFingerCount = clamped
                return
            }
            UserDefaults.standard.set(readerLongPressFingerCount, forKey: readerFingerCountKey)
        }
    }

    /// Whether reader mode also hides the iOS status bar. Default off
    /// — most users still want to glance at time/battery while reading.
    /// On = fully-immersive (Lecteur Safari / Kindle style).
    public var readerHidesStatusBar: Bool {
        didSet {
            UserDefaults.standard.set(readerHidesStatusBar, forKey: readerHidesStatusBarKey)
        }
    }

    /// Whether the CreateBubble accessory is hidden when the user is
    /// not at the library root (i.e. inside a shelf, leaf or book).
    /// **Default OFF** — the bubble stays visible everywhere so a
    /// fresh user always has the four primary creation buttons one
    /// tap away. Power users who want a quieter chrome inside a leaf
    /// can flip the toggle ON in Settings → Create bubble.
    public var hidesAccessoryOutsideLibraryRoot: Bool {
        didSet {
            UserDefaults.standard.set(hidesAccessoryOutsideLibraryRoot, forKey: hidesAccessoryOffRootKey)
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
    /// `Leaf.theme` overrides this when set.
    public var theme: Theme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: themeKey)
        }
    }

    /// Light / dark / system override applied at the app root via
    /// `.preferredColorScheme(_:)`. Default `.system` follows iOS.
    public var appearance: AppearanceMode {
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
    public func applyAppearanceToWindows() {
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

    public init() {
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
        // Default ON — same "absent key means default, not false"
        // guard, since `bool(forKey:)` cannot distinguish the two.
        if UserDefaults.standard.object(forKey: linkPreviewsKey) != nil {
            self.linkPreviewsEnabled = UserDefaults.standard.bool(forKey: linkPreviewsKey)
        } else {
            self.linkPreviewsEnabled = true
        }
        // Default OFF — preserves the existing landscape behaviour
        // for users who haven't touched the toggle yet.
        self.rotationLocked = UserDefaults.standard.bool(forKey: AppSettings.rotationLockKey)
        // Reader mode defaults — gesture on, 2 fingers, status bar visible.
        if UserDefaults.standard.object(forKey: readerLongPressEnabledKey) != nil {
            self.readerLongPressEnabled = UserDefaults.standard.bool(forKey: readerLongPressEnabledKey)
        } else {
            self.readerLongPressEnabled = true
        }
        let storedFingers = UserDefaults.standard.integer(forKey: readerFingerCountKey)
        self.readerLongPressFingerCount = (2...3).contains(storedFingers) ? storedFingers : 2
        self.readerHidesStatusBar = UserDefaults.standard.bool(forKey: readerHidesStatusBarKey)
        // Default OFF — the bubble stays visible everywhere by
        // default so fresh users always see the creation actions
        // one tap away. Power users opt in to quieter chrome in
        // Settings.
        self.hidesAccessoryOutsideLibraryRoot = UserDefaults.standard.bool(forKey: hidesAccessoryOffRootKey)
    }

    public var accentColor: Color { accentChoice.color }

    /// Resets every preference back to its factory default —
    /// accent = orange, spotlight tint off, recent count = 7. Used
    /// by the floating "Reset" button in `SettingsView`.
    public func resetToDefaults() {
        accentChoice              = .blue
        spotlightTinted           = false
        recentCount               = 7
        cursorFollowsAccent       = true
        appearance                = .system
        theme                     = .original
        hapticsEnabled            = true
        linkPreviewsEnabled       = true
        rotationLocked            = false
        readerLongPressEnabled    = true
        readerLongPressFingerCount = 2
        readerHidesStatusBar      = false
        hidesAccessoryOutsideLibraryRoot = false
    }
}
