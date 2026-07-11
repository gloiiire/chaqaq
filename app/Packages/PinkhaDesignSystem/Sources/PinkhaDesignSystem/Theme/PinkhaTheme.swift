import SwiftUI

// MARK: - Theme bundle
//
// A single value that carries every visual choice a feature might need to
// re-theme: accent, spacing scale, radii, motion preferences. Injected via
// `\.pinkhaTheme` in `PinkhaTheme+Environment.swift` so any View can read
// the current theme with `@Environment(\.pinkhaTheme) var theme`.
//
// **Do not scatter individual `@Environment` reads for accent + spacing +
// radius.** Read the theme bundle and pull members off it — that keeps
// call sites concise and lets us evolve the bundle without touching
// every consumer.

public struct PinkhaTheme: Sendable {
    /// The accent applied to prominent controls and buttons. Prefer this
    /// over `.tint(...)` at the feature level so re-theming a Leaf's
    /// chrome flows through automatically.
    public var accent: Color

    public init(accent: Color = .accentColor) {
        self.accent = accent
    }

    /// The default theme — accent from environment.
    public static let `default` = PinkhaTheme()

    /// A themed copy with a specific accent. Convenience for Leaf-scoped
    /// re-themes (`theme.withAccent(leaf.accentColor.pinkhaAccent?.color)`).
    public func withAccent(_ color: Color) -> PinkhaTheme {
        var copy = self
        copy.accent = color
        return copy
    }
}

// Note: `PinkhaSpacing` is a SwiftUI `DynamicProperty` (@ScaledMetric-based) so
// it cannot live inside a plain value — features declare it as a stored
// property on their View instead:
//
//   struct MyView: View {
//       var spacing = PinkhaSpacing()          // SwiftUI DynamicProperty
//       @Environment(\.pinkhaTheme) var theme
//
//       var body: some View {
//           VStack(spacing: spacing.m) { ... }
//               .tint(theme.accent)
//       }
//   }
