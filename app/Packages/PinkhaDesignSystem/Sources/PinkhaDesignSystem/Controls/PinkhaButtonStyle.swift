import SwiftUI

// MARK: - Pinkha button style
//
// The single ButtonStyle every feature uses for prominent CTAs. Reads
// `.tint` from the environment (feature sets it), respects `role:` for
// destructive framing, and inherits DT via `.headline` typography.
//
// **There is no `.primary/.secondary/.destructive` variant enum.** Use
// Apple's `role: .destructive` on the `Button` itself, and `.tint(...)`
// on an ancestor for accent. That's the iOS-idiomatic pattern.
//
// Example:
//   Button("Save") { save() }
//     .buttonStyle(.pinkha)
//     .tint(theme.accent)
//
//   Button(role: .destructive) { delete() } label: { Text("Delete") }
//     .buttonStyle(.pinkha)

public struct PinkhaButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PinkhaButtonBody(configuration: configuration)
    }
}

private struct PinkhaButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    /// The tint applied by an ancestor via `.tint(...)`. `nil` falls back
    /// to `.accentColor` which itself reads from the app environment.
    private var tint: Color { .accentColor }

    var body: some View {
        configuration.label
            .font(.pinkhaHeadline)
            .foregroundStyle(fillForeground)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: PinkhaRadius.l, style: .continuous)
                    .fill(fillBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: PinkhaRadius.l, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.5)
            .animation(.spring(response: 0.28, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }

    private var fillBackground: Color {
        if configuration.role == .destructive {
            return Color.red.opacity(configuration.isPressed ? 0.9 : 1.0)
        }
        return tint.opacity(configuration.isPressed ? 0.85 : 1.0)
    }

    private var fillForeground: Color { .white }
}

public extension ButtonStyle where Self == PinkhaButtonStyle {
    /// The canonical pinkha prominent button. Combine with `.tint(...)`.
    static var pinkha: PinkhaButtonStyle { .init() }
}
