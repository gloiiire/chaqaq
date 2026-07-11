import SwiftUI

// MARK: - Theme environment binding
//
// The iOS 18+ `@Entry` macro removes the `EnvironmentKey` boilerplate —
// one line to declare a custom environment value. Features read
// `@Environment(\.pinkhaTheme) var theme` and pull members off it.
//
// Root injection lives in the app composition root:
//   TabView { ... }
//     .environment(\.pinkhaTheme, .default)
// and re-scoped views (e.g. LeafView) override just the accent:
//     .environment(\.pinkhaTheme, theme.withAccent(vm.accentColor))

public extension EnvironmentValues {
    @Entry var pinkhaTheme: PinkhaTheme = .default
}

public extension View {
    /// Sugar for setting the theme bundle in one call.
    func pinkhaTheme(_ theme: PinkhaTheme) -> some View {
        environment(\.pinkhaTheme, theme)
    }
}
