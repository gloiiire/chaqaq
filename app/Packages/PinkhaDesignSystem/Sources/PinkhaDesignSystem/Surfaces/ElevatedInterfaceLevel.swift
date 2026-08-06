import SwiftUI
import UIKit

/// Raises the whole app off pure black in dark mode.
///
/// In dark mode iOS resolves `systemBackground` and `systemGroupedBackground`
/// to **#000000**. Full-screen on an OLED that reads as a dead panel: the
/// page has no plane, so cards and sheets float with nothing behind them.
///
/// The fix is not a hand-picked grey. UIKit already ships a second rung of
/// the same ramp — the *elevated* interface level, which it applies
/// automatically to modally presented content. At that level the same
/// semantic colours resolve to:
///
/// | Colour | base (dark) | elevated (dark) |
/// | --- | --- | --- |
/// | `systemBackground` / `systemGroupedBackground` | `#000000` | `#1C1C1E` |
/// | `secondarySystemGroupedBackground` | `#1C1C1E` | `#2C2C2E` |
///
/// Setting the level on the window therefore lifts the page **and** the rows
/// together, keeping their separation intact. Overriding only the page — the
/// obvious first attempt — moves it to within 3 points of luminance of the
/// still-black-based rows, which makes the cards *less* legible, not more.
/// That was measured, not assumed.
///
/// It also makes the app agree with its own sheets, which were already
/// elevated: the reader's customize sheet was measured at exactly
/// `#1C1C1E` / `#2C2C2E`.
///
/// `traitOverrides` is iOS 17+; the app targets 26.
private final class ElevatingProbe: UIView {
    /// `didMoveToWindow` is the only reliable moment: a representable's
    /// `updateUIView` runs before the view is in the hierarchy, when
    /// `window` is still nil, and SwiftUI has no reason to call it again
    /// once the window arrives — the first attempt applied nothing.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        window?.traitOverrides.userInterfaceLevel = .elevated
    }
}

private struct ElevatedInterfaceLevel: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = ElevatingProbe(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.window?.traitOverrides.userInterfaceLevel = .elevated
    }
}

public extension View {
    /// Applies the elevated interface level to the hosting window.
    /// Attach once, at the app's root view.
    func pinkhaElevatedSurfaces() -> some View {
        background(ElevatedInterfaceLevel().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
