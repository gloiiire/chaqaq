import Testing
import SwiftUI
import UIKit
@testable import PinkhaDesignSystem

// Dark mode rendered pure black, because every surface token forwards to
// a system colour and iOS resolves those to #000000 in dark.
//
// The fix raises the window to UIKit's *elevated* interface level rather
// than hardcoding a grey. These tests pin the two properties that made
// that the right call, either of which iOS could change under us.

@Suite("Surface tokens — elevated dark is off pure black")
struct PinkhaSurfaceTokenTests {

    private func rgb(_ color: Color, elevated: Bool) -> (Int, Int, Int) {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark),
            UITraitCollection(userInterfaceLevel: elevated ? .elevated : .base),
        ])
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    private func luminance(_ c: (Int, Int, Int)) -> Double {
        0.299 * Double(c.0) + 0.587 * Double(c.1) + 0.114 * Double(c.2)
    }

    /// The premise of the whole change: at base level these are black, at
    /// elevated they are not. If iOS ever collapsed the two, the app would
    /// silently go back to a dead panel.
    @Test func elevatingLiftsTheRootOffBlack() {
        for token in [Color.pinkhaSurface, .pinkhaGrouped] {
            #expect(luminance(rgb(token, elevated: false)) == 0)
            #expect(luminance(rgb(token, elevated: true)) > 20)
        }
    }

    /// The trap that the first attempt fell into: raising the page alone
    /// left the rows on their base colour, three points of luminance away,
    /// which made cards *less* legible. Elevating moves both, so the gap
    /// has to survive.
    @Test func rowsStayClearlyAboveThePageWhenElevated() {
        let page = luminance(rgb(Color.pinkhaGrouped, elevated: true))
        let row  = luminance(rgb(Color.pinkhaGroupedElevated, elevated: true))
        #expect(row - page > 10, "cards would not read against the page")
    }

    /// The "Original" reader theme has no palette of its own: its surface
    /// is the app's, resolved explicitly for the appearance the reader
    /// asked for rather than read from the environment. Reading it from
    /// the environment would make the leaf depend on `preferredColorScheme`
    /// flowing back down into `.background`, which the five named themes
    /// never have to rely on because they carry fixed colours.
    @Test func explicitSurfaceResolutionFollowsTheRequestedAppearance() {
        let dark = luminance(rgbOf(Color.pinkhaSurface(dark: true)))
        let light = luminance(rgbOf(Color.pinkhaSurface(dark: false)))
        #expect(light > dark, "light must be lighter than dark")
        #expect(dark > 20, "must not fall back to pure black")
        #expect(light > 200, "light surface must actually be light")
    }

    /// Text has to travel with the surface, otherwise picking Light on a
    /// dark device gives white text on a white page.
    @Test func explicitLabelResolutionOpposesTheSurface() {
        #expect(luminance(rgbOf(Color.pinkhaLabel(dark: false)))
                < luminance(rgbOf(Color.pinkhaSurface(dark: false))))
        #expect(luminance(rgbOf(Color.pinkhaLabel(dark: true)))
                > luminance(rgbOf(Color.pinkhaSurface(dark: true))))
    }

    /// Resolves an already-concrete colour (no trait lookup needed).
    private func rgbOf(_ color: Color) -> (Int, Int, Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// Same requirement for the ungrouped family, used by the leaf editor.
    @Test func elevatedSurfaceStaysAboveTheRootSurface() {
        let root = luminance(rgb(Color.pinkhaSurface, elevated: true))
        #expect(luminance(rgb(Color.pinkhaSurfaceElevated, elevated: true)) > root)
    }
}
