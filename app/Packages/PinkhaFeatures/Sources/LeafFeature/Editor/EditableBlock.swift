import SwiftUI
import PinkhaFFI

// ── Editable model ────────────────────────────────────────────────────────────

/// In-memory representation of a block being edited. Captures the content,
/// spans and "done" state so the UI can update optimistically without waiting for SQLite.
public struct EditableBlock: Identifiable, Equatable {
    public let id: String
    public var content: BlockContentFfi
    public var spans: [InlineTextFfi]
    public var done: Bool
    /// Block-level text color (matches Rust `Block.color`). When set, applies
    /// to every span that has no inline `.color(...)` override.
    public var color: String? = nil
    /// Block-level *background* color (Craft / Notion highlight).
    /// Painted as a soft tinted band behind the whole block content.
    /// Independent from `color`. Matches `Block.background_color`.
    public var backgroundColor: String? = nil
    /// Per-block writing direction (`"ltr"` / `"rtl"`). `nil` inherits
    /// the leaf-level direction. Matches `Block.text_direction`.
    public var textDirection: String? = nil
    /// Nesting depth (0 = top-level). The Rust domain models nesting as a
    /// recursive `Block.children` tree, but the editor UI renders a flat
    /// list — we flatten the tree at load time and use this depth to apply a
    /// left-padding so indented blocks appear indented. Indent/outdent then
    /// mutate the underlying tree on the Rust side; the next reload produces
    /// the same flat list with the updated depths.
    public var depth: Int = 0
    public var plainText: String { spans.map(\.content).joined() }
}

// ── Action repeater ───────────────────────────────────────────────────────────
// Repeats a closure at a fixed interval (key repeat for navigation arrows).
// Task-based so the repeat loop is cancellable and MainActor-isolated —
// no Timer, no Sendable friction on the captured VM method, and tests can
// drive it with a short interval instead of racing a real run-loop timer.

/// Fires a closure at a regular interval while a navigation key is held down.
@MainActor
public final class ActionRepeater {
    private var task: Task<Void, Never>?
    public var active: Bool { task != nil }

    /// Starts repeating `step` every `interval` seconds. A second call while
    /// active is a no-op. Matches the old Timer semantics : the first fire
    /// happens after one full `interval`, not immediately.
    func start(interval: TimeInterval = 0.12, _ step: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                step()
            }
        }
    }

    /// Cancels the repeat loop.
    func stop() {
        task?.cancel()
        task = nil
    }
}

// ── Block types ────────────────────────────────────────────────────────────────

/// All block types the user can insert via the block picker.
public enum NewBlockType: String, CaseIterable, Identifiable {
    case text = "Text", title1 = "Title 1", title2 = "Title 2", title3 = "Title 3"
    case quote = "Quote", callout = "Callout", todo = "To do"
    case bulleted = "Bulleted list", numbered = "Numbered list"
    case divider = "Divider"
    public var id: String { rawValue }
    /// User-facing label resolved through `Localizable.xcstrings`.
    /// `rawValue` is a `String` which SwiftUI never localizes, so call
    /// sites must use this key — see [[localizedstringkey-trap]].
    public var displayName: LocalizedStringKey {
        switch self {
        case .text:     return "Text"
        case .title1:   return "Title 1"
        case .title2:   return "Title 2"
        case .title3:   return "Title 3"
        case .quote:    return "Quote"
        case .callout:  return "Callout"
        case .todo:     return "To do"
        case .bulleted: return "Bulleted list"
        case .numbered: return "Numbered list"
        case .divider:  return "Divider"
        }
    }
    public var icone: String {
        switch self {
        case .text:     return "text.alignleft"
        case .title1:   return "1.circle.fill"
        case .title2:   return "2.circle"
        case .title3:   return "3.circle"
        case .quote:    return "quote.bubble"
        case .callout:  return "lightbulb"
        case .todo:     return "checkmark.square"
        case .bulleted: return "list.bullet"
        case .numbered: return "list.number"
        case .divider:  return "minus"
        }
    }
}
