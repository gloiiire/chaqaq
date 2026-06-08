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
final class AppSettings: ObservableObject {
    /// Catalogue of accent colors offered in the picker. Keeping the
    /// mapping name → Color in one place lets us persist a stable
    /// string in UserDefaults (Color isn't `Codable` cleanly) and round-
    /// trip it on relaunch.
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

        var label: String {
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

        var label: String { rawValue.capitalized }
    }

    private let accentKey         = "pinkha.settings.accentColor"
    private let spotlightKey      = "pinkha.settings.spotlightTinted"
    private let recentCountKey    = "pinkha.settings.recentCount"
    private let cursorAccentKey   = "pinkha.settings.cursorFollowsAccent"
    private let appearanceKey     = "pinkha.settings.appearance"

    /// When on, the text-input caret + selection highlight use the
    /// chosen accent color. Off by default (white, à la Notion) so
    /// the cursor stays quiet against most block colors.
    @Published var cursorFollowsAccent: Bool {
        didSet {
            UserDefaults.standard.set(cursorFollowsAccent, forKey: cursorAccentKey)
        }
    }

    /// How many docs the "Recent" strip on the Notes home shows.
    /// Bounded 5–20 ; 7 is the default that fits ~2 fully-visible
    /// cards plus a peek of a third on iPhone 17 Pro.
    @Published var recentCount: Int {
        didSet {
            let clamped = max(5, min(20, recentCount))
            if clamped != recentCount {
                recentCount = clamped
                return
            }
            UserDefaults.standard.set(recentCount, forKey: recentCountKey)
        }
    }

    @Published var accentChoice: AccentChoice {
        didSet {
            UserDefaults.standard.set(accentChoice.rawValue, forKey: accentKey)
        }
    }

    @Published var spotlightTinted: Bool {
        didSet {
            UserDefaults.standard.set(spotlightTinted, forKey: spotlightKey)
        }
    }

    /// Light / dark / system override applied at the app root via
    /// `.preferredColorScheme(_:)`. Default `.system` follows iOS.
    @Published var appearance: AppearanceMode {
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
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { $0.overrideUserInterfaceStyle = style }
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
    }
}
