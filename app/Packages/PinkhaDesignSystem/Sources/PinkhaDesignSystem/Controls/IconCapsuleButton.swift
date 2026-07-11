import SwiftUI

// MARK: - Icon capsule button
//
// The 44×44 glass capsule button pattern that recurs across the app: sheet
// close buttons, floating actions, toolbar dismissals. Encapsulates
//   Image(systemName: …)
//     .frame(width: 44, height: 44)
//     .contentShape(Circle())
//     .glassEffect(.regular.interactive(), in: Circle())
// so features stop re-implementing it inline (see `ReaderSettingsSheet`,
// `CreateLeafSheet`, etc.).
//
// The 44×44 frame matches Apple's minimum tap target (HIG Layout). The
// symbol is centred, colour uses `Color.primary` for automatic vibrancy
// over Liquid Glass — pass `tint:` only when you deliberately want a
// non-material foreground.

public struct IconCapsuleButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void
    /// Optional tint override. `nil` means `.primary` (respects vibrancy).
    let tint: Color?
    /// Optional role — pass `.destructive` for a red-tinted glyph.
    let role: ButtonRole?

    public init(
        systemImage: String,
        accessibilityLabel: String,
        tint: Color? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.tint = tint
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(effectiveTint)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pinkhaGlassCapsule(in: Circle())
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var effectiveTint: Color {
        if role == .destructive { return .red }
        return tint ?? .primary
    }
}
