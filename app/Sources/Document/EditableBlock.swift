import SwiftUI

// ── Editable model ────────────────────────────────────────────────────────────

/// In-memory representation of a block being edited. Captures the content,
/// spans and "done" state so the UI can update optimistically without waiting for SQLite.
struct EditableBlock: Identifiable, Equatable {
    let id: String
    var content: BlockContentFfi
    var spans: [InlineTextFfi]
    var done: Bool
    /// Block-level text color (matches Rust `Block.color`). When set, applies
    /// to every span that has no inline `.color(...)` override.
    var color: String? = nil
    var plainText: String { spans.map(\.content).joined() }
}

// ── Action repeater ───────────────────────────────────────────────────────────
// Repeats a closure at a fixed interval (key repeat for navigation arrows).
// Encapsulates the Timer logic to keep the view model clean.

/// Fires a closure at a regular interval while a navigation key is held down.
final class ActionRepeater {
    private var timer: Timer?
    var active: Bool { timer != nil }

    /// Starts repeating `step` every `interval` seconds. A second call while active is a no-op.
    func start(interval: TimeInterval = 0.12, _ step: @escaping () -> Void) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in step() }
    }

    /// Stops the repeat timer.
    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// ── Block types ────────────────────────────────────────────────────────────────

/// All block types the user can insert via the block picker.
enum NewBlockType: String, CaseIterable, Identifiable {
    case text = "Text", title1 = "Title 1", title2 = "Title 2", title3 = "Title 3"
    case quote = "Quote", callout = "Callout", todo = "To do", divider = "Divider"
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
