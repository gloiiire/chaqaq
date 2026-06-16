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
// Encapsulates the Timer logic to keep the view model clean.

/// Fires a closure at a regular interval while a navigation key is held down.
public final class ActionRepeater {
    private var timer: Timer?
    public var active: Bool { timer != nil }

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
public enum NewBlockType: String, CaseIterable, Identifiable {
    case text = "Text", title1 = "Title 1", title2 = "Title 2", title3 = "Title 3"
    case quote = "Quote", callout = "Callout", todo = "To do", divider = "Divider"
    public var id: String { rawValue }
    /// User-facing label resolved through `Localizable.xcstrings`.
    /// `rawValue` is a `String` which SwiftUI never localizes, so call
    /// sites must use this key — see [[localizedstringkey-trap]].
    public var displayName: LocalizedStringKey {
        switch self {
        case .text:    return "Text"
        case .title1:  return "Title 1"
        case .title2:  return "Title 2"
        case .title3:  return "Title 3"
        case .quote:   return "Quote"
        case .callout: return "Callout"
        case .todo:    return "To do"
        case .divider: return "Divider"
        }
    }
    public var icone: String {
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
