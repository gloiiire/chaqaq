// ── Raccourcis markdown ───────────────────────────────────────────────────────

/// Convertit un raccourci markdown en son équivalent `BlockContentFfi`.
/// Retourne `nil` si `text` n'est pas un raccourci reconnu.
/// Fonction pure — testable indépendamment sans couche UI.
func markdownShortcut(for text: String) -> BlockContentFfi? {
    switch text {
    case "# ":          return .heading(level: 1, text: [])
    case "## ":         return .heading(level: 2, text: [])
    case "### ":        return .heading(level: 3, text: [])
    case "> ":          return .quote(icon: "", text: [])
    case "!! ":         return .quote(icon: "💡", text: [])
    case "[ ] ", "[] ": return .todo(done: false, text: [])
    case "---":         return .divider
    default:            return nil
    }
}
