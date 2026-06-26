import SwiftUI
import PinkhaCore
import PinkhaComposer

// ── Create bubble (Apple Music mini-player style) ────────────────────────────
//
// A single glass capsule hosting four tappable icons — same composition
// rule as Apple Music's mini-player accessory : one shared glass surface,
// the action icons sit directly on it (no individual chrome). Sitting in
// the iOS 26 `tabViewBottomAccessory` slot, the capsule docks at the tab
// bar's vertical level alongside the auto-positioned search bubble.

/// Single glass accessory with three primary create actions and an
/// overflow menu — leaf / book / shelf / more.
///
/// The capsule is the only glass surface; the icons are plain images.
/// Mirrors Apple Music's mini-player layout (play / next).
public struct CreateBubble: View {
    public init(
        onNewLeaf: @escaping () -> Void,
        onNewBook: @escaping () -> Void,
        onNewShelf: @escaping () -> Void,
        onShowTrash: @escaping () -> Void = {},
        onDeleteAll: @escaping () -> Void = {},
        hasItemsForDeleteAll: Bool = false,
        onImportNotion: @escaping () -> Void = {},
        onImportBear: @escaping () -> Void = {},
        onImportCraftTextBundle: @escaping () -> Void = {},
        onImportCraftCombined: @escaping () -> Void = {},
        onShowAllLeaves: @escaping () -> Void = {}
    ) {
        self.onNewLeaf = onNewLeaf
        self.onNewBook = onNewBook
        self.onNewShelf = onNewShelf
        self.onShowTrash = onShowTrash
        self.onDeleteAll = onDeleteAll
        self.hasItemsForDeleteAll = hasItemsForDeleteAll
        self.onImportNotion = onImportNotion
        self.onImportBear = onImportBear
        self.onImportCraftTextBundle = onImportCraftTextBundle
        self.onImportCraftCombined = onImportCraftCombined
        self.onShowAllLeaves = onShowAllLeaves
    }
    public let onNewLeaf: () -> Void
    public let onNewBook: () -> Void
    public let onNewShelf: () -> Void
    // Overflow menu actions — exposed here so the navbar can drop its
    // own ellipsis (the bubble is the new single source of secondary
    // actions). Default to no-op for the visual placement tests.
    public var onShowTrash: () -> Void = {}
    public var onDeleteAll: () -> Void = {}
    public var hasItemsForDeleteAll: Bool = false
    public var onImportNotion: () -> Void = {}
    public var onImportBear: () -> Void = {}
    public var onImportCraftTextBundle: () -> Void = {}
    public var onImportCraftCombined: () -> Void = {}
    /// Opens the Safari-tab-style "All leaves" switcher. Lives in
    /// the overflow menu next to Trash / Imports — it's a navigation
    /// affordance, not a creation one.
    public var onShowAllLeaves: () -> Void = {}

    /// Tracks whether the accessory is rendered next to the minimised tab
    /// bar (`.inline`) or detached above it (`.expanded`). Set automatically
    /// by SwiftUI when the bubble lives inside `tabViewBottomAccessory`.
    /// Drives a tighter layout in inline mode so the four icons match the
    /// compact bubble width without crowding.
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    /// "Where am I?" — read here so each primary button can decide
    /// whether its action makes sense in the current view. Same
    /// `Composer` instance that PRO-56 reads to route the actual
    /// creation; we only read `currentContext`.
    @Environment(Composer.self) private var composer

    /// User can swipe the expanded bubble to the right to collapse it
    /// into the inline visual layout without waiting for the tab bar to
    /// minimise itself. Resets the next time the system promotes the
    /// accessory back to expanded (i.e. the user scrolls up and the
    /// tab bar restores its full layout).
    @State private var manuallyCollapsed: Bool = false

    private var isInline: Bool { placement == .inline || manuallyCollapsed }

    // ── Per-button enablement (PRO-57) ────────────────────────────────────
    //
    // The bubble exposes 3 primary creation actions. Some make no sense in
    // some contexts (you can't create a Shelf inside a Leaf — `parent_leaf_id`
    // isn't a Shelf concept). We grey out those buttons rather than letting
    // the tap silently land work at root.
    //
    //   Context       | 🍃 Leaf | 📚 Book | 📁 Shelf
    //   ----          | ----    | ----    | ----
    //   .root         | ✅      | ✅      | ✅
    //   .shelf        | ✅      | ✅†     | ✅ (sub-shelf)
    //   .leaf         | ✅ (child)| ❌    | ❌
    //   .book         | ✅ (row)| ❌      | ❌
    //
    //   † Today books always land at root regardless of shelf context —
    //   PRO-56 documented this as a Rust-side dependency (no `Book.shelf_id`).

    private var isLeafEnabled: Bool {
        Self.isLeafEnabled(in: composer.currentContext)
    }
    private var isBookEnabled: Bool {
        Self.isBookEnabled(in: composer.currentContext)
    }
    private var isShelfEnabled: Bool {
        Self.isShelfEnabled(in: composer.currentContext)
    }

    /// Pure helpers — extracted so the rules can be unit-tested without
    /// instantiating a `CreateBubble` and its SwiftUI environment.
    static func isLeafEnabled(in context: Composer.CreationContext) -> Bool {
        // Every context accepts a new leaf : root → loose, shelf → filed,
        // leaf → child page, book → row.
        true
    }
    static func isBookEnabled(in context: Composer.CreationContext) -> Bool {
        switch context {
        case .root, .shelf: return true
        case .leaf, .book:  return false
        }
    }
    static func isShelfEnabled(in context: Composer.CreationContext) -> Bool {
        switch context {
        case .root, .shelf: return true
        case .leaf, .book:  return false
        }
    }

    public var body: some View {
        HStack(spacing: isInline ? 3 : 30) {
            // `doc.badge.plus` is taller than the other three glyphs
            // (because of the badge composition), so we render it one
            // step smaller (.body vs .title3) to keep the row visually
            // balanced. The label still uses the same caption style so
            // the baseline anchors stay consistent.
            icon(systemImage: "doc.badge.plus",
                 label: "Leaf",
								 font: .system(size: 21),
								 labelSpacing: 0,
                 isEnabled: isLeafEnabled,
								 action: onNewLeaf)
              .offset(y:isInline ? 2.1 : -1)
              .accessibilityIdentifier("createLeafFAB")
            icon(systemImage: "book.badge.plus",
                 label: "Book",
                 isEnabled: isBookEnabled,
                 action: onNewBook)
              // .offset(y:isInline?)
              .accessibilityIdentifier("createBookFAB")
            icon(systemImage: "books.vertical",
                 label: "Shelf",
                 isEnabled: isShelfEnabled,
                 action: onNewShelf)
              .accessibilityIdentifier("createShelfFAB")
            overflowMenu
                .accessibilityIdentifier("createFAB")
        }
        .padding(.horizontal, isInline ? 3 : 12)
        .padding(.vertical, 10)
        .animation(.snappy, value: isInline)
        // None of the bubble icons are "selected" affordances —
        // overflow the TabView's accent tint by pinning the whole
        // subtree (Leaf / Book / Shelf / More + everything in
        // the More menu) to the neutral material color.
        .tint(.primary)
        // Swipe right on the expanded capsule to shrink it back to the
        // inline layout. `minimumDistance: 20` keeps the tap targets on
        // the four icons hit-tester friendly; the horizontal/vertical
        // ratio check rejects accidental vertical pans.
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard placement != .inline else { return }
                    let dx = value.translation.width
                    let dy = abs(value.translation.height)
                    if dx > 40, dx > dy * 2 {
                        Haptic.soft()
                        manuallyCollapsed = true
                    }
                }
        )
        .onChange(of: placement) { _, newValue in
            // System restored the expanded slot — clear the manual
            // override so the labels reappear next time around.
            if newValue != .inline { manuallyCollapsed = false }
        }
    }

    private func icon(systemImage: String,
                      label: LocalizedStringKey,
                      font: Font = .title3,
                      labelSpacing: CGFloat = 2,
                      isEnabled: Bool = true,
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
        // `.disabled` blocks the tap AND tells VoiceOver the control
        // is unavailable. The .opacity gives the visual cue users
        // expect for greyed-out controls (matches the system disabled-
        // button affordance without overriding tint).
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.35)
        .animation(.easeInOut(duration: 0.15), value: isEnabled)
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
            // Source-order inversion : putting "All leaves" LAST in
            // the source list lands it FIRST visually because iOS
            // bottom-anchored menus stack from the trigger upwards.
            Button { onShowAllLeaves() } label: {
                Label("All leaves", systemImage: "document.on.document")
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
