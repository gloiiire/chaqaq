import UIKit

/// Teinte de sélection globale (fallback vers systemOrange si l'asset est absent).
let pinkhaSelectionTint = UIColor(named: "SelectionTint") ?? .systemOrange

// ── Clés d'attributs personnalisées ──────────────────────────────────────────

extension NSAttributedString.Key {
    /// Stocke le nom de couleur en parallèle de `.foregroundColor` pour un round-trip fiable
    /// entre `NSAttributedString` et `[InlineTextFfi]`.
    static let pinkhaColor  = NSAttributedString.Key("com.pinkha.color")
    /// Marque un segment comme explicitement gras (survit aux réinitialisations de `typingAttributes` par UIKit).
    static let pinkhaBold   = NSAttributedString.Key("com.pinkha.bold")
    /// Marque un segment comme explicitement italique.
    static let pinkhaItalic = NSAttributedString.Key("com.pinkha.italic")
    /// Valeur d'obliquité stockée avec l'italique pour les polices où `withSymbolicTraits` échoue.
    static let pinkhaObliqueness = NSAttributedString.Key("NSObliqueness")
}

// ── Utilitaires de police ─────────────────────────────────────────────────────

/// Retourne une police dérivée de `base` avec les traits gras/italique demandés.
/// Utilise `boldSystemFont`/`italicSystemFont` en fallback quand `withSymbolicTraits` retourne `nil`
/// (SF Pro ne propage pas toujours les traits dans certains contextes iOS).
func fontWithTraits(_ base: UIFont, bold: Bool, italic: Bool) -> UIFont {
    let size = base.pointSize
    let traitsBase = base.fontDescriptor.symbolicTraits
    let renduBold = bold || traitsBase.contains(.traitBold)
    let renduItalic = italic || traitsBase.contains(.traitItalic)
    switch (renduBold, renduItalic) {
    case (true, true):
        let desc = UIFont.boldSystemFont(ofSize: size).fontDescriptor
        if let d = desc.withSymbolicTraits([.traitBold, .traitItalic]) { return UIFont(descriptor: d, size: size) }
        return UIFont.boldSystemFont(ofSize: size)
    case (true, false):  return UIFont.boldSystemFont(ofSize: size)
    case (false, true):  return UIFont.italicSystemFont(ofSize: size)
    case (false, false): return base
    }
}

/// Retourne une police italique à la taille et graisse données.
/// `.italicSystemFont` est toujours regular, donc ce helper applique le trait italic
/// à un descripteur de police pondéré quand c'est possible.
func italicFontWithWeight(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
    let base = UIFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
        return UIFont(descriptor: d, size: size)
    }
    return .italicSystemFont(ofSize: size)
}

/// Convertit un nom de couleur (français ou anglais) en `UIColor`.
/// Les noms inconnus retombent sur `.label` pour que le texte reste lisible.
func uiColorFromName(_ nom: String) -> UIColor {
    switch nom.lowercased() {
    case "rouge", "red":             return .systemRed
    case "rose", "pink":             return .systemPink
    case "orange":                   return .systemOrange
    case "jaune", "yellow":          return .systemYellow
    case "vert", "green":            return .systemGreen
    case "cyan", "menthe", "mint":   return .cyan
    case "bleu", "blue":             return .systemBlue
    case "violet", "purple":         return .systemPurple
    case "marron", "brown":          return .brown
    case "gris", "gray":             return .systemGray
    default:                         return .label
    }
}
