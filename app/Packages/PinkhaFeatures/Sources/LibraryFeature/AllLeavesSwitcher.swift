import SwiftUI
import PinkhaCore
import PinkhaComposer
import LeafFeature

// ── Safari-tab-style "All leaves" switcher ────────────────────────────────

/// Full-screen takeover presented from the bottom-accessory overflow
/// menu (`More → All leaves`). Lays the entire library out as a
/// 2-column grid of phone-shaped cards, à la Safari's multi-tab
/// switcher : the actual rendered title + content snippet for each
/// doc (so the cards are distinguishable even when they share a
/// cover image), a small favicon-style label underneath, and a
/// top-right search icon that filters the visible cards in place.
public struct AllLeavesSwitcher: View {
    public init(store: PinkhaStore, onSelect: @escaping (String) -> Void) {
        self.store = store
        self.onSelect = onSelect
    }
    @Bindable public var store: PinkhaStore
    public let onSelect: (String) -> Void
    @Environment(AppSettings.self) private var settings
    @Environment(TabManager.self) private var tabManager
    @Environment(Composer.self) private var composer
    @Environment(\.dismiss) private var dismiss

    @State private var searching = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    public var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            if filteredItems.isEmpty {
                LibraryEmptyState()
            } else {
                grid
            }

            VStack {
                topBar
                Spacer()
                bottomToolbar
            }
        }
    }

    /// Tabs the user has opened in the current session, MRU first.
    /// Looked up from `store.items` so the switcher uses the latest
    /// title / cover (the doc metadata is always more current than
    /// the cached VM, which only knows what it loaded last).
    private var openItems: [WorkspaceItem] {
        let store = store.items
        return tabManager.openTabs.compactMap { tab in
            store.first { $0.id == tab.leafId }
        }
    }

    private var filteredItems: [WorkspaceItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return openItems }
        return openItems.filter {
            $0.titlePlain.localizedCaseInsensitiveContains(trimmed)
        }
    }

    // ── Top bar (Safari pattern : `...` left, title center, search right) ─

    private var topBar: some View {
        HStack(spacing: 10) {
            if searching {
                // Search expanded : the search field grows to fill,
                // X dismisses. Matches Safari's "search mode".
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search leaves", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .submitLabel(.search)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .glassEffect(.regular, in: Capsule(style: .continuous))

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        searching = false
                        searchText = ""
                        searchFocused = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Close search")
            } else {
                // `...` overflow menu — Safari pattern.
                Menu {
                    if !tabManager.recentlyClosed.isEmpty {
                        Button {
                            if let api = store.api {
                                _ = withAnimation(.easeInOut(duration: 0.25)) {
                                    tabManager.reopenLastClosed(api: api)
                                }
                            }
                        } label: {
                            Label("Reopen closed leaf",
                                  systemImage: "arrow.uturn.backward")
                        }
                        Divider()
                    }
                    Button(role: .destructive) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            tabManager.closeAll()
                        }
                    } label: {
                        // iOS 26 quirk : `role: .destructive` alone
                        // colours the text red but not the SF Symbol;
                        // `.tint(.red)` alone colours the icon but not
                        // the text. Combining the two gives both —
                        // they target different parts of the menu
                        // item's rendering path.
                        Label("Close all leaves", systemImage: "xmark.bin")
                    }
                    .tint(.red)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("More")

                Spacer()

                // Center pill — Safari has the library/account picker
                // here. We surface the doc count + the implicit "All
                // leaves" scope. Tapping does nothing for now (we
                // don't have workspaces yet) but the pill anchors the
                // visual.
                Text("All leaves")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .glassEffect(.regular, in: Capsule(style: .continuous))

                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        searching = true
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(50))
                        searchFocused = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Search")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        // Neutral chrome convention : the search-field cursor, the
        // clear button, and the close glyph all inherit the env tint.
        // Without this they pick up the surrounding TabView's accent
        // (blue/orange/etc) — we want them in `.primary` so they
        // read as system chrome, not as opt-in accent UI.
        .tint(.primary)
    }

    // ── Grid ─────────────────────────────────────────────────────────────

    private var grid: some View {
        // `SafariSwitcher` — pure-UIKit, single-master-gesture switcher
        // matching Safari's SFTabSwitcher architecture. Replaces the
        // earlier `TabGridView` (UICollectionView + UIHostingConfiguration)
        // whose touch routing fought our pan gesture. See
        // `docs/SAFARI-TAB-GRID-RE.md` and `SafariSwitcher.swift`.
        SafariSwitcher(
            items: filteredItems,
            api: store.api,
            accent: settings.accentColor,
            onSelect: { leafId in onSelect(leafId) },
            onClose: { leafId in tabManager.close(leafId: leafId) }
        )
    }

    // ── Bottom Safari-style toolbar ──────────────────────────────────────
    //
    // Layout matches Safari iOS 26 :
    //   `+` (left, glass circle)   N tabs pill (center, large glass)   `✓` (right, accent circle)

    private var bottomToolbar: some View {
        HStack(spacing: 14) {
            Button {
                // Create new leaf → dismisses the switcher + triggers
                // the CreateBubble's primary action via Composer.
                dismiss()
                composer.showingCreateDoc = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.regular))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("New leaf")

            Spacer()

            // Compact count pill — hugs the text, no excess padding.
            // `inflect:` drives the plural ("1 leaf" / "2 leaves"
            // / "0 leaf"), with the FR plural rules served from
            // Localizable.xcstrings.
            Text("^[\(filteredItems.count) leaf](inflect: true)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .glassEffect(.regular, in: Capsule(style: .continuous))

            Spacer()

            Button {
                if tabManager.openTabs.isEmpty {
                    // Force the Library tab + force-recreate the home
                    // view (.id bump → fresh @State → empty path →
                    // NavStack at root). This is the only reliable
                    // way past the SwiftUI bug where external path
                    // mutations don't always pop the visible stack.
                    composer.selectedTab = .leaves
                    composer.leavesHomeKey += 1
                }
                dismiss()
            } label: {
                Image(systemName: "checkmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .background(settings.accentColor, in: Circle())
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
    }
}
