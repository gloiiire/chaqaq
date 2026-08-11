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
        Self.elevate(window)
    }

    /// Écrit le niveau SEULEMENT s'il diffère.
    ///
    /// Écrire dans `traitOverrides` n'est pas une affectation anodine :
    /// UIKit repropage un changement de traits à TOUTE la hiérarchie de
    /// la fenêtre, et chaque vue reçoit `traitCollectionDidChange`. Le
    /// faire à chaque passe de rendu — ce que fait `updateUIView` — coûte
    /// d'autant plus cher que la hiérarchie est grosse : une leaf
    /// déverrouillée porte un `UITextView` par bloc.
    ///
    /// La garde existait dans la première version et a été perdue en
    /// réécrivant avec cette sonde. Sans elle, le téléphone chauffe.
    static func elevate(_ window: UIWindow?) {
        // Comparer le trait RÉSOLU, jamais l'override.
        //
        // Lire `traitOverrides.userInterfaceLevel` avant d'en avoir posé
        // un fait planter l'app au lancement — constaté ici : les 224
        // tests unitaires passaient sans ce fichier et échouaient avec,
        // sur « The test runner crashed before establishing connection ».
        // `simctl launch` ne l'avait pas montré : il rend la main dès que
        // le processus démarre, donc un crash immédiat passe pour un
        // lancement réussi.
        //
        // `traitCollection.userInterfaceLevel` est toujours lisible et
        // répond à la vraie question : la fenêtre est-elle déjà élevée ?
        guard let window, window.traitCollection.userInterfaceLevel != .elevated
        else { return }
        window.traitOverrides.userInterfaceLevel = .elevated
    }
}

private struct ElevatedInterfaceLevel: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = ElevatingProbe(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        ElevatingProbe.elevate(view.window)
    }
}

public extension View {
    /// Applies the elevated interface level to the hosting window.
    /// Attach once, at the app's root view.
    func pinkhaElevatedSurfaces() -> some View {
        background(ElevatedInterfaceLevel().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

public extension Color {
    /// La surface de l'app résolue pour une apparence DONNÉE, sans passer
    /// par l'environnement.
    ///
    /// Le thème « Original » n'a pas de palette : sa surface est celle de
    /// l'app, une couleur dynamique. Lire cette couleur depuis
    /// l'environnement reviendrait à parier que `.preferredColorScheme`
    /// a bien reflué jusqu'au `.background` — un pari que les cinq autres
    /// thèmes n'ont pas à faire, puisqu'ils portent des couleurs fixes.
    /// On résout donc explicitement, avec le niveau élevé pour rester sur
    /// la même rampe que le reste de l'app (cf. `ElevatedInterfaceLevel`).
    static func pinkhaSurface(dark: Bool) -> Color {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
            UITraitCollection(userInterfaceLevel: .elevated),
        ])
        return Color(uiColor: UIColor(Color.pinkhaSurface).resolvedColor(with: traits))
    }

    /// Pendant de `pinkhaSurface(dark:)` pour le texte.
    static func pinkhaLabel(dark: Bool) -> Color {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
            UITraitCollection(userInterfaceLevel: .elevated),
        ])
        return Color(uiColor: UIColor.label.resolvedColor(with: traits))
    }
}
