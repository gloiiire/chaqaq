import SwiftUI

// ── Editable model ────────────────────────────────────────────────────────────

/// Représentation en mémoire d'un bloc en cours d'édition. Capture le contenu,
/// les spans et l'état "done" pour permettre à l'UI de se mettre à jour de manière
/// optimiste sans attendre SQLite.
struct EditableBlock: Identifiable, Equatable {
    let id: String
    var content: BlockContentFfi
    var spans: [InlineTextFfi]
    var done: Bool
    var plainText: String { spans.map(\.content).joined() }
}

// ── Action repeater ───────────────────────────────────────────────────────────
// Répète une closure à intervalle fixe (répétition de touche pour les flèches de navigation).
// Encapsule la logique Timer pour garder le view model propre.

/// Déclenche une closure à intervalle régulier tant qu'une touche de navigation est maintenue.
final class ActionRepeater {
    private var timer: Timer?
    var active: Bool { timer != nil }

    /// Démarre la répétition de `step` à `interval` secondes. Un second appel pendant l'activité est ignoré.
    func start(interval: TimeInterval = 0.12, _ step: @escaping () -> Void) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in step() }
    }

    /// Arrête le timer de répétition.
    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// ── Block types ────────────────────────────────────────────────────────────────

/// Tous les types de blocs que l'utilisateur peut insérer via le sélecteur de blocs.
enum NewBlockType: String, CaseIterable, Identifiable {
    case text = "Texte", title1 = "Titre 1", title2 = "Titre 2", title3 = "Titre 3"
    case quote = "Citation", callout = "Callout", todo = "À faire", divider = "Séparateur"
    var id: String { rawValue }
    var icone: String {
        switch self {
        case .text:    return "text.alignleft"
        case .title1:  return "1.circle.fill"
        case .title2:  return "2.circle"
        case .title3:  return "3.circle"
        case .quote:   return "quote.bubble"
        case .callout: return "lightbulb"
        case .todo:    return "checkmark.square"
        case .divider: return "minus"
        }
    }
}
