import SwiftUI
import UIKit

/// Pont vers `UIActivityViewController` pour proposer un fichier à
/// l'utilisateur (Fichiers, AirDrop, Mail…).
///
/// Pourquoi pas `ShareLink` : il exige de connaître l'élément au moment de
/// construire la vue, or notre archive n'existe qu'après un travail
/// asynchrone. Et pourquoi pas `fileExporter` : il passe par un
/// `FileDocument`, donc par un `Data` chargé en mémoire — une bibliothèque
/// de plusieurs dizaines de mégaoctets avec ses couvertures n'a pas à
/// transiter par la RAM. `UIActivityViewController` lit depuis le disque.
public struct ShareSheet: UIViewControllerRepresentable {
    private let fichiers: [URL]
    private let onTermine: (() -> Void)?

    public init(fichiers: [URL], onTermine: (() -> Void)? = nil) {
        self.fichiers = fichiers
        self.onTermine = onTermine
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: fichiers, applicationActivities: nil)
        // Appelé aussi bien après un partage réussi qu'après une annulation :
        // dans les deux cas l'archive temporaire a fait son office et le
        // ménage peut se faire.
        vc.completionWithItemsHandler = { _, _, _, _ in onTermine?() }
        return vc
    }

    public func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
