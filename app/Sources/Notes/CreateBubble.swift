import SwiftUI

// ── Create bubble (Apple Music mini-player style) ────────────────────────────
//
// A single glass capsule hosting four tappable icons — same composition
// rule as Apple Music's mini-player accessory : one shared glass surface,
// the action icons sit directly on it (no individual chrome). Sitting in
// the iOS 26 `tabViewBottomAccessory` slot, the capsule docks at the tab
// bar's vertical level alongside the auto-positioned search bubble.

/// Single glass accessory with three primary create actions and an
/// overflow menu — note / database / folder / more.
///
/// The capsule is the only glass surface; the icons are plain images.
/// Mirrors Apple Music's mini-player layout (play / next).
struct CreateBubble: View {
    let onNewNote: () -> Void
    let onNewDatabase: () -> Void
    let onNewFolder: () -> Void
    // Overflow menu actions — exposed here so the navbar can drop its
    // own ellipsis (the bubble is the new single source of secondary
    // actions). Default to no-op for the visual placement tests.
    var onShowTrash: () -> Void = {}
    var onDeleteAll: () -> Void = {}
    var hasItemsForDeleteAll: Bool = false
    var onImportNotion: () -> Void = {}
    var onImportBear: () -> Void = {}
    var onImportCraftTextBundle: () -> Void = {}
    var onImportCraftCombined: () -> Void = {}
    /// Opens the Safari-tab-style "All documents" switcher. Lives in
    /// the overflow menu next to Trash / Imports — it's a navigation
    /// affordance, not a creation one.
    var onShowAllDocs: () -> Void = {}

    /// Tracks whether the accessory is rendered next to the minimised tab
    /// bar (`.inline`) or detached above it (`.expanded`). Set automatically
    /// by SwiftUI when the bubble lives inside `tabViewBottomAccessory`.
    /// Drives a tighter layout in inline mode so the four icons match the
    /// compact bubble width without crowding.
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { placement == .inline }

    var body: some View {
        HStack(spacing: isInline ? 3 : 30) {
            // `doc.badge.plus` is taller than the other three glyphs
            // (because of the badge composition), so we render it one
            // step smaller (.body vs .title3) to keep the row visually
            // balanced. The label still uses the same caption style so
            // the baseline anchors stay consistent.
            icon(systemImage: "doc.badge.plus",
                 label: "Note",
								 font: .system(size: 21),
								 labelSpacing: 0,
								 action: onNewNote)
						.offset(y:isInline ? 2.1 : -1)
            icon(systemImage: "tablecells",
                 label: "Database",
                 action: onNewDatabase)
            icon(systemImage: "folder.badge.plus",
                 label: "Folder",
                 action: onNewFolder)
            overflowMenu
        }
        .padding(.horizontal, isInline ? 3 : 12)
        .padding(.vertical, 10)
        .animation(.snappy, value: isInline)
        // None of the bubble icons are "selected" affordances —
        // overflow the TabView's accent tint by pinning the whole
        // subtree (Note / Database / Folder / More + everything in
        // the More menu) to the neutral material color.
        .tint(.primary)
    }

    private func icon(systemImage: String,
                      label: LocalizedStringKey,
                      font: Font = .title3,
                      labelSpacing: CGFloat = 2,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: labelSpacing) {
                Image(systemName: systemImage)
                    .font(font.weight(.regular))
                if !isInline {
                    Text(label)
                        .font(.system(size: 9, weight: .regular))
                        .transition(.opacity)
                }
            }
            .frame(minWidth: 48, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    /// Overflow menu — consolidates the secondary actions (trash, imports,
    /// destructive wipe) so the navbar can drop its own ellipsis.
    ///
    /// Source-order note : iOS lays out a bottom-anchored Menu from its
    /// trigger upwards, so the first source item ends up visually closest
    /// to the button (i.e. at the bottom of the deployed menu) and the
    /// last item floats at the top. We reverse the natural reading order
    /// here so the visual order is Trash → Import → Delete all.
    private var overflowMenu: some View {
        Menu {
            if hasItemsForDeleteAll {
                // Pin the destructive action to system red — the app-level
                // `.tint(...)` would otherwise repaint the icon in the
                // user's accent color, weakening the danger signal.
                Button(role: .destructive) { onDeleteAll() } label: {
                    Label("Delete all", systemImage: "trash.slash")
                }
                .tint(.red)
                Divider()
            }
            Button { onShowTrash() } label: {
                Label("Trash", systemImage: "trash")
            }
            Divider()
            Menu {
                // Same inversion trick as the parent overflow menu —
                // source order reads bottom-up so the visual layout from
                // top to bottom is Notion → Craft → Bear.
                Button { onImportBear() } label: {
                    Label("Bear", systemImage: "pencil.and.list.clipboard")
                }
                Menu {
                    Button { onImportCraftCombined() } label: {
                        Label("TextBundle + Realm", systemImage: "arrow.triangle.merge")
                    }
                    Button { onImportCraftTextBundle() } label: {
                        Label("TextBundle", systemImage: "doc.zipper")
                    }
                } label: {
                    Label("Craft", systemImage: "paintpalette")
                }
                Button { onImportNotion() } label: {
                    Label("Notion", systemImage: "arrow.down.doc")
                }
            } label: {
                Label("Import from…", systemImage: "square.and.arrow.down")
            }
            Divider()
            // Source-order inversion : putting "All documents" LAST in
            // the source list lands it FIRST visually because iOS
            // bottom-anchored menus stack from the trigger upwards.
            Button { onShowAllDocs() } label: {
                Label("All documents", systemImage: "square.stack")
            }
        } label: {
            VStack(spacing: 4) {
                // The `ellipsis` glyph renders centred in its bounding box
                // and visually higher than `doc.text` / `tablecells` etc.,
                // which are top-heavy. We frame it to the same height as
                // the others and nudge it down with `.offset(y:)` so its
                // visual baseline matches — `.offset` shifts the render
                // without disturbing the layout (idiomatic SwiftUI fix for
                // small visual asymmetries like this).
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.regular))
                    .frame(height: 22)
                    // The ellipsis sits visually higher than the other
                    // glyphs because its tight 3-dot shape centres at a
                    // different baseline. Nudge it down in both modes —
                    // more in expanded (label anchored to row baseline)
                    // than in inline (just visual centring).
                    .offset(y: isInline ? 2 : 4)
                if !isInline {
                    Text("More")
                        .font(.system(size: 9, weight: .regular))
												.transition(.opacity)
												.offset(y: 0)
                }
            }
            .frame(minWidth: 48, minHeight: 48)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("More actions")
    }
}
