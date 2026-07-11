import SwiftUI

// MARK: - Spacing scale
//
// Apple does NOT ship a rigid rem-style spacing scale — HIG treats spacing as
// contextual (safe area, list row insets, section margins, default `.padding()`).
// pinkha's DS follows suit: the tokens below are `@ScaledMetric` values
// relative to `.body`, so they grow with Dynamic Type instead of imposing
// a fixed grid that breaks at accessibility sizes.
//
// **Only use these tokens when you would have hand-picked a magic number.**
// Prefer `.padding()` (no argument) — SwiftUI's default already accounts
// for size class and container semantics.
//
// Multiples-of-4 are the informal convention (Apple UIKit metrics), but
// the tokens are the source of truth; do not hardcode.

public struct PinkhaSpacing: DynamicProperty {
    /// 4 pt at default DT — tightest gap (icon to label, badge padding).
    @ScaledMetric(relativeTo: .body) public var xs: CGFloat = 4
    /// 8 pt — related-group spacing (title over subtitle).
    @ScaledMetric(relativeTo: .body) public var s: CGFloat = 8
    /// 12 pt — inline row insets, card interior.
    @ScaledMetric(relativeTo: .body) public var m: CGFloat = 12
    /// 16 pt — default view padding, most inter-element gaps.
    @ScaledMetric(relativeTo: .body) public var l: CGFloat = 16
    /// 24 pt — inter-section separation.
    @ScaledMetric(relativeTo: .body) public var xl: CGFloat = 24
    /// 32 pt — hero spacing, top-of-screen breathing room.
    @ScaledMetric(relativeTo: .body) public var xxl: CGFloat = 32

    public init() {}
}
