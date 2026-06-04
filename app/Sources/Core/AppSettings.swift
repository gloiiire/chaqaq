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

    private let accentKey    = "pinkha.settings.accentColor"
    private let spotlightKey = "pinkha.settings.spotlightTinted"

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

    init() {
        let stored = UserDefaults.standard.string(forKey: accentKey)
        self.accentChoice = AccentChoice(rawValue: stored ?? "") ?? .orange
        // Default off — matches the latest preference. A user that
        // wants the tint flips the toggle in Settings.
        self.spotlightTinted = UserDefaults.standard.bool(forKey: spotlightKey)
    }

    var accentColor: Color { accentChoice.color }
}
