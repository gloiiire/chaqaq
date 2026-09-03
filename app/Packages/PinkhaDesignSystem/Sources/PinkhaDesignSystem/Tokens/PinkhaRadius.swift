import SwiftUI

// MARK: - Corner radius scale
//
// A small set of named radii keeps rounded shapes coherent across surfaces.
// The `concentric` helper implements WWDC25's concentricity rule
// (child radius = parent radius − padding) so nested cards feel geometrically
// aligned instead of visually floating.

public enum PinkhaRadius {
    /// 6 pt — small chips, tag pills, tiny badges.
    public static let xs: CGFloat = 6
    /// 10 pt — inline swatches, secondary cards.
    public static let s: CGFloat = 10
    /// 14 pt — list rows, callouts.
    public static let m: CGFloat = 14
    /// 20 pt — primary card, cover thumbnail.
    public static let l: CGFloat = 20
    /// 28 pt — hero card, full-screen sheet corner.
    public static let xl: CGFloat = 28

    /// The concentric child radius that visually aligns with a parent whose
    /// radius is `parent` and whose interior padding to this child is
    /// `padding`. Never returns below 0 (clamped for tight nesting).
    public static func concentric(parent: CGFloat, padding: CGFloat) -> CGFloat {
        max(0, parent - padding)
    }
}
