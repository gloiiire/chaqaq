import SwiftUI
import UIKit

// ── System-style alert card ───────────────────────────────────────────────────
//
// Reusable building block for in-app alerts that must look indistinguishable
// from a native iOS 26 `UIAlertController` (Liquid Glass).
//
// The visual constants below are derived from a class-dump of `UIKitCore`
// (iOS 26.5 simulator runtime), specifically `UIAlertControllerVisualStyle`
// and `UIAlertControllerVisualStyleAlertGlassTV`:
//   • contentCornerRadius       → 36 pt, continuous
//   • contentShadowRadius       → ~32 pt
//   • contentShadowOpacity      → ~0.28
//   • contentShadowOffset       → (0, 18)
//   • alertAnimationInitialScale → > 1 (the card shrinks IN, doesn't grow)
//
// Layout matches the iOS 26 vocabulary: ~320 pt cap, left-aligned title +
// message, full-width material-fill capsule actions with soft drop shadow,
// 20 % dim layer behind. Use this card every time we need a custom alert
// surface ; do NOT roll your own glass + shadow combo in a feature view.

/// A drop-in clone of an iOS 26 alert card. Pass a title, optional message,
/// optional progress indicator and one or more actions ; the card paints
/// itself with the same glass, shadow and animation as `UIAlertController`.
///
/// Wrap in a `ZStack` with a dim layer to use as a full-screen modal — see
/// `View.systemAlertOverlay(isPresented:)` for the standard presentation.
public struct SystemAlertCard: View {
    public init(title: LocalizedStringKey, message: LocalizedStringKey? = nil,
                showsProgress: Bool = false, actions: [Action]) {
        self.title = title; self.message = message
        self.showsProgress = showsProgress; self.actions = actions
    }
    public let title: LocalizedStringKey
    public var message: LocalizedStringKey? = nil
    /// `true` renders a small spinner above the title — for progress alerts
    /// where the background work is non-cancellable in real time.
    public var showsProgress: Bool = false
    public let actions: [Action]

    /// One alert action. Mirrors SwiftUI's `Alert.Button` vocabulary so the
    /// call site reads like a stock `.alert` modifier.
    public struct Action: Identifiable {
        public let id = UUID()
        public let title: LocalizedStringKey
        public var role: ButtonRole? = nil
        public let handler: () -> Void

        public static func cancel(_ title: LocalizedStringKey = "Cancel",
                           handler: @escaping () -> Void = {}) -> Self {
            Action(title: title, role: .cancel, handler: handler)
        }

        public static func destructive(_ title: LocalizedStringKey,
                                handler: @escaping () -> Void) -> Self {
            Action(title: title, role: .destructive, handler: handler)
        }

        public static func `default`(_ title: LocalizedStringKey,
                              handler: @escaping () -> Void) -> Self {
            Action(title: title, role: nil, handler: handler)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if showsProgress {
                    ProgressView()
                        .padding(.bottom, 6)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 18)

            VStack(spacing: 10) {
                ForEach(actions) { action in
                    Self.actionButton(action)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: 320)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
        // contentShadow* on UIAlertControllerVisualStyle — the soft glow
        // that separates the card from the dimmer.
        .shadow(color: .black.opacity(0.28), radius: 32, x: 0, y: 18)
    }

    /// Builds one alert action button. Native iOS 26 alert actions use a
    /// glass-fill capsule with the role colour applied to the label only ;
    /// `.buttonStyle(.glass)` layered on the card's own glass would refract
    /// nothing, so we paint the capsule with a dedicated `.glassEffect` to
    /// match the action sheet look (`UIAlertActionVisualStyleGlassTV`).
    @ViewBuilder
    private static func actionButton(_ action: Action) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action.handler()
        } label: {
            Text(action.title)
                .fontWeight(.semibold)
                .foregroundStyle(labelStyle(for: action.role))
                .frame(maxWidth: .infinity, minHeight: 50)
                .glassEffect(.regular, in: Capsule(style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }

    private static func labelStyle(for role: ButtonRole?) -> AnyShapeStyle {
        switch role {
        case .destructive: return AnyShapeStyle(Color.red)
        case .cancel: return AnyShapeStyle(.primary)
        default: return AnyShapeStyle(.tint)
        }
    }
}

// ── Standard presentation modifier ───────────────────────────────────────────

public extension View {
    /// Presents a `SystemAlertCard` as a modal overlay : 20 % dim layer
    /// (alert dim level), tap-swallowing background, and the alert-style
    /// scale + opacity transition. `alertAnimationInitialScale` from
    /// `UIAlertControllerVisualStyleAlertGlassTV` is > 1, so the card
    /// shrinks in instead of growing.
    ///
    /// Use this everywhere a custom alert is needed — never roll your own
    /// glass + shadow + transition combo in a feature view. Call sites
    /// just provide the card content :
    ///
    ///     .systemAlertOverlay(isPresented: $showing) {
    ///         SystemAlertCard(
    ///             title: "Importing from Notion",
    ///             message: "Book 1 of 1",
    ///             showsProgress: true,
    ///             actions: [.destructive("Cancel import") { … }]
    ///         )
    ///     }
    func systemAlertOverlay<Card: View>(
        isPresented: Bool,
        @ViewBuilder card: () -> Card
    ) -> some View {
        let cardView = card()
        return overlay {
            if isPresented {
                ZStack {
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()
                    cardView
                        .transition(.scale(scale: 1.15).combined(with: .opacity))
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82),
                   value: isPresented)
    }
}
