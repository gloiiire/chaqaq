#if canImport(UIKit)
import UIKit
#endif
import SwiftUI

// MARK: - Surface primitives
//
// Semantic wrappers over Apple's material APIs. Features call
// `.pinkhaCard()` / `.pinkhaChrome()` / `.pinkhaGlassBar()` instead of
// choosing between `.regularMaterial` / `.thickMaterial` / `.glassEffect`
// themselves — the DS owns the layering choice so the app reads coherently.
//
// **Never stack these on top of each other.** Materials over materials
// muddies vibrancy — separate layers with `.pinkhaFillSecondary` (opaque)
// or straight `.pinkhaSurfaceElevated` when nesting is needed (WWDC25:
// "Meet Liquid Glass").

public extension View {

    /// Elevated card background — used for callouts, recent tiles,
    /// property rows. Semantic wrapper over `.regularMaterial` with a
    /// medium radius. Falls back to `.thickMaterial` on iOS 26 where
    /// Liquid Glass is not yet available.
    func pinkhaCard(radius: CGFloat = PinkhaRadius.m) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Toolbar / navbar chrome background — the flat `.bar` material
    /// Apple ships for edge-attached controls. Do NOT use for cards.
    func pinkhaChrome() -> some View {
        background(.bar)
    }

    /// Liquid Glass capsule for floating controls (FAB, undo pill,
    /// close buttons). Interactive means the material reacts to touch
    /// with a subtle press animation. iOS 27 uses the true Liquid Glass;
    /// iOS 26 falls back to `.regularMaterial` in a Circle shape.
    @ViewBuilder
    func pinkhaGlassCapsule<S: Shape>(in shape: S) -> some View {
        if #available(iOS 27.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// Alert / sheet backdrop — the semi-opaque Liquid Glass panel used
    /// for modal presentations. Sets `.presentationBackground(.thinMaterial)`
    /// under the hood and disables the automatic dim so the sheet reads
    /// as a translucent panel over the underlying content.
    @available(iOS 16.4, *)
    func pinkhaSheetBackground() -> some View {
        self.presentationBackground(.thinMaterial)
    }
}
