import SwiftUI

/// First-impression splash shown on cold launch. Mirrors Deblock.app's
/// pattern: the logo fades + scales in over the system background while
/// the rest of the app finishes wiring itself up, then dissolves into
/// the real content. The system-coloured background matches the
/// default `UILaunchScreen` so the iOS-rendered launch image flows
/// straight into this view with no flash.
struct SplashView: View {
    /// Two-stage entrance — first the logo materialises (fade + slight
    /// scale-up), then on dismiss it scales up a touch more while the
    /// whole splash fades away. The combined motion reads as the logo
    /// "opening up into the app" rather than disappearing.
    @State private var logoVisible = false
    /// Set by the parent via the parent's `withAnimation` block — used
    /// here to slightly enlarge the logo just before dissolve so the
    /// outgoing motion feels continuous with the fade-out.
    var isDismissing: Bool

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .scaleEffect(scale)
                .opacity(logoVisible ? 1 : 0)
                // Sits in the upper third of the screen rather than
                // dead-centred — feels closer to Deblock's framing and
                // leaves headroom for the dissolve into the app's
                // top-aligned navigation title.
								.offset(y: -15)
                .accessibilityHidden(true)
        }
        .onAppear {
            // Slow-in over 700 ms — Deblock-pace, enough for the eye
            // to register the logo before anything else happens.
            withAnimation(.easeOut(duration: 0.7)) {
                logoVisible = true
            }
        }
    }

    /// Combined scale curve: 0.85 (pre-appear) → 1.0 (presented) →
    /// 1.08 (dissolving). The final overshoot is what makes the exit
    /// feel intentional instead of a hard cut.
    private var scale: CGFloat {
        if isDismissing { return 1.08 }
        return logoVisible ? 1.0 : 0.85
    }
}
