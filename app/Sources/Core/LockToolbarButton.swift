import SwiftUI

/// Animated lock toolbar button shared by `DocumentView` and
/// `DatabaseView`. Each tap kicks off a keyframe sequence :
///
/// 1. **Wind-up** : the symbol shrinks (0.7) and tilts a little
///    counter-clockwise (-22°) — feels like the user is pinching
///    the padlock before turning.
/// 2. **Snap** : it springs back past 1.0 (overshoots to 1.30) while
///    untilting and swapping the SF Symbol mid-flight via
///    `.replace.magic` so the shackle morph happens at peak scale.
/// 3. **Settle** : spring damping brings it back to rest.
///
/// The SF Symbol replace alone reads as "the icon just changed".
/// The keyframe scale + tilt + over-bounce reads as "I just clicked
/// a padlock". Big perceptual difference.
struct LockToolbarButton: View {
    let locked: Bool
    let accent: Color
    let onTap: () -> Void
    /// Increments on every toggle ; the keyframe animator is driven
    /// by this counter rather than `locked` directly so a tap that
    /// re-locks an already-locked button (shouldn't happen, but…)
    /// still replays the animation instead of being short-circuited.
    @State private var clickCount: Int = 0

    var body: some View {
        Button {
            clickCount &+= 1
            onTap()
        } label: {
            Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                .contentTransition(
                    .symbolEffect(.replace.magic(fallback: .replace.downUp))
                )
                .keyframeAnimator(
                    initialValue: AnimState(scale: 1, rotation: 0),
                    trigger: clickCount
                ) { content, state in
                    content
                        .scaleEffect(state.scale)
                        .rotationEffect(.degrees(state.rotation))
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(0.70, duration: 0.10)
                        CubicKeyframe(1.30, duration: 0.18)
                        SpringKeyframe(
                            1.00, duration: 0.32,
                            spring: .bouncy(duration: 0.32, extraBounce: 0.25)
                        )
                    }
                    KeyframeTrack(\.rotation) {
                        CubicKeyframe(-22, duration: 0.10)
                        CubicKeyframe( 10, duration: 0.18)
                        SpringKeyframe(
                            0, duration: 0.32,
                            spring: .bouncy(duration: 0.32, extraBounce: 0.25)
                        )
                    }
                }
        }
        .tint(locked ? accent : .primary)
        .accessibilityLabel(locked ? "Unlock" : "Lock")
    }
}

/// Two-axis state used by the keyframe track. Wraps scale + rotation
/// so the animator can interpolate them together.
private struct AnimState: Animatable {
    var scale: CGFloat
    var rotation: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(scale, rotation) }
        set { scale = newValue.first; rotation = newValue.second }
    }
}
