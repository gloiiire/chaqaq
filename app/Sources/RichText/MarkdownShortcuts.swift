// ── Markdown shortcuts ────────────────────────────────────────────────────────

/// Converts a markdown shortcut to its `BlockContentFfi` equivalent.
/// Returns `nil` if `text` is not a recognized shortcut.
/// Pure function — independently testable without a UI layer.
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
