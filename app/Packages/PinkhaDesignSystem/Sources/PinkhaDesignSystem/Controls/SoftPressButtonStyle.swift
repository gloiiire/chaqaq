import SwiftUI

// MARK: - Soft press animation
//
// The Apple-standard press feel: a tiny scale-down + opacity dip while the
// finger is on the control, spring back on release. Matches the animation
// Apple applies internally to `.glassEffect(.regular.interactive())` so
// non-glass buttons feel physically consistent with glass ones.
//
// Prefer this over hand-rolled `.scaleEffect` inside features — the timing
// curve here is the one Apple uses in Books.app / Music.app.

public struct SoftPressButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == SoftPressButtonStyle {
    /// A soft press animation matching Apple's internal press timing.
    static var pinkhaSoftPress: SoftPressButtonStyle { .init() }
}
