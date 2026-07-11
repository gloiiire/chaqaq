import SwiftUI

// MARK: - Motion tokens
//
// Named animation presets that map to Apple's WWDC-taught motion tiers:
// `fast` for micro-feedback (button press, chip select), `default` for
// standard state transitions, `emphasized` for content changes that
// carry meaning (opening a leaf, entering reader mode), `smooth` for
// scroll-tracking interpolations.
//
// The tokens are `Animation` values — use with `withAnimation(_:)` or
// `.animation(_:value:)`. Do not compose ad-hoc timing curves in
// features when a token fits — the vocabulary keeps motion coherent.

public enum PinkhaMotion {
    /// 0.15 s — micro-feedback (press, hover, toggle).
    public static let fast: Animation = .easeInOut(duration: 0.15)
    /// 0.25 s — standard state transitions.
    public static let `default`: Animation = .easeInOut(duration: 0.25)
    /// 0.35 s — emphasized content transitions (mode change, sheet).
    public static let emphasized: Animation = .easeInOut(duration: 0.35)
    /// Spring — scroll-tracked interpolation (offset changes, drag response).
    public static let smooth: Animation = .interpolatingSpring(
        mass: 1, stiffness: 240, damping: 32
    )
}
