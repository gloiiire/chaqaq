import PinkhaFFI

// ── Markdown shortcuts ────────────────────────────────────────────────────────

/// Converts a markdown shortcut found at the START of `text` into its
/// `BlockContentFfi` equivalent. Whatever follows the shortcut prefix
/// is preserved as a single plain-text inline span so a "# title" or
/// "> quote with content already typed" conversion keeps the words
/// the user has written. Inline styles on the trailing text aren't
/// preserved by this layer — the editor re-syncs from spans after
/// the convert, and bold/italic that were applied past the shortcut
/// are turned back to plain text.
///
/// `"---"` is the one exception: it only matches as a whole-line
/// shortcut and produces a `.divider` with no carry-over content.
///
/// Pure function — independently testable without a UI layer.
func markdownShortcut(for text: String) -> BlockContentFfi? {
    // Whole-line shortcuts (no trailing content)
    if text == "---" { return .divider }

    // Prefix shortcuts — listed longest-first so "## " wins over "# "
    // when the user types `### `.
    let prefixes: [(prefix: String, build: ([InlineTextFfi]) -> BlockContentFfi)] = [
        ("### ", { .heading(level: 3, text: $0) }),
        ("## ",  { .heading(level: 2, text: $0) }),
        ("# ",   { .heading(level: 1, text: $0) }),
        ("> ",   { .quote(icon: "", text: $0) }),
        ("!! ",  { .quote(icon: "💡", text: $0) }),
        ("[ ] ", { .todo(done: false, text: $0) }),
        ("[] ",  { .todo(done: false, text: $0) }),
    ]
    for (prefix, build) in prefixes where text.hasPrefix(prefix) {
        let trailing = String(text.dropFirst(prefix.count))
        let spans: [InlineTextFfi] = trailing.isEmpty
            ? []
            : [InlineTextFfi(content: trailing, styles: [])]
        return build(spans)
    }
    return nil
}

/// Styled-spans variant of `markdownShortcut(for:)`. Identical
/// prefix-matching logic, but the trailing content keeps its inline
/// styles (bold, italic, color, …) instead of being flattened to a
/// single plain span. The editor calls this from `textViewDidChange`
/// with the just-extracted `attributedToSpans(...)` so a conversion
/// like `# **Hello**` → H1 with the bold preserved.
func markdownShortcut(for text: String,
                      spans: [InlineTextFfi]) -> BlockContentFfi? {
    if text == "---" { return .divider }

    let prefixes: [(prefix: String, build: ([InlineTextFfi]) -> BlockContentFfi)] = [
        ("### ", { .heading(level: 3, text: $0) }),
        ("## ",  { .heading(level: 2, text: $0) }),
        ("# ",   { .heading(level: 1, text: $0) }),
        ("> ",   { .quote(icon: "", text: $0) }),
        ("!! ",  { .quote(icon: "💡", text: $0) }),
        ("[ ] ", { .todo(done: false, text: $0) }),
        ("[] ",  { .todo(done: false, text: $0) }),
    ]
    for (prefix, build) in prefixes where text.hasPrefix(prefix) {
        let stripped = stripLeadingChars(prefix.count, from: spans)
        return build(stripped)
    }
    return nil
}

/// Drops the first `count` characters from a span sequence while
/// preserving the styles of any partially-cut span. Unicode-safe
/// (uses `String.Index` arithmetic, not byte offsets).
func stripLeadingChars(_ count: Int,
                       from spans: [InlineTextFfi]) -> [InlineTextFfi] {
    var remaining = count
    var result: [InlineTextFfi] = []
    for span in spans {
        if remaining <= 0 {
            result.append(span)
            continue
        }
        let spanLen = span.content.count
        if spanLen <= remaining {
            remaining -= spanLen
            continue
        }
        let cutIdx = span.content.index(span.content.startIndex, offsetBy: remaining)
        let rest = String(span.content[cutIdx...])
        result.append(InlineTextFfi(content: rest, styles: span.styles))
        remaining = 0
    }
    return result
}
