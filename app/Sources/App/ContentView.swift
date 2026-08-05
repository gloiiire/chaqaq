import SwiftUI
import PinkhaFFI
import PinkhaCore
import PinkhaComposer
import LeafFeature
import SearchFeature
import BookFeature
import LibraryFeature
import ImportFeature

// ── Root view: 4-tab layout ──────────────────────────────────────────────────

/// Root view — four tabs: Leafs, Books, Inbox, Search. The create
/// bubble lives in the TabView's bottom accessory so it docks alongside
/// the auto-positioned search bubble at the same vertical level as the
/// tab bar (iOS 26 multi-bubble layout, à la Photos / Music).
struct ContentView: View {
    @State private var store = PinkhaStore()
    @State private var composer = Composer()
    @State private var tabManager = TabManager()
    @State private var readerMode = ReaderMode()
    @Environment(AppSettings.self) private var settings

    /// Tracks crossing of the swipe-up haptic threshold so we fire
    /// the "ready to commit" tap exactly once per drag, not on every
    /// pixel past the line.
    @State private var swipeUpHapticFired = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            tabsChrome
            // Floating exit button — only visible in reader mode. Sits
            // in the top-right safe-area so it doesn't overlap the leaf
            // content the user is reading. Glass capsule mirrors the
            // CreateBubble's surface vocabulary.
            if readerMode.isActive {
                readerExitButton
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: readerMode.isActive)
        // Multi-finger long-press gesture installed at the window
        // level — sees every touch without participating in hit-testing.
        // Reader mode is a leaf-only affordance : entering it from the
        // library home or a book picker would just hide a tab bar with
        // nothing to read. We guard on `composer.currentContext` here
        // so the gesture is a no-op outside a leaf ; the same guard
        // applies to the toggle from LeafView's overflow menu (the
        // menu is simply absent on non-leaf surfaces).
        .multiFingerLongPress(
            enabled: settings.readerLongPressEnabled,
            fingerCount: settings.readerLongPressFingerCount
        ) {
            switch composer.currentContext {
            case .leaf:               readerMode.toggle()
            case .root, .shelf, .book:
                // Exit gesture still works even when not "in" a leaf
                // — if the user somehow ended up in reader mode and
                // navigated away, they can always come out.
                if readerMode.isActive { readerMode.deactivate() }
            }
        }
        // Status bar hide is opt-in — most users want time/battery
        // visible while reading, but Lecteur-Safari fans can opt into
        // full immersion via the setting.
        .statusBarHidden(readerMode.isActive && settings.readerHidesStatusBar)
        .environment(readerMode)
    }

    /// Wraps the existing tab-view + chrome stack. Extracted so the
    /// reader-mode overlay can live alongside it without having to
    /// thread all the modifiers through a second branch.
    @ViewBuilder
    private var tabsChrome: some View {
        rootTabs
            // iOS 26 tab-bar morphing : the tab bar collapses when the user
            // scrolls down so the content gets more breathing room, and
            // reappears on scroll-up.
            .tabBarMinimizeBehavior(.onScrollDown)
            // What actually detaches Search into its own bubble. iOS 27
            // reserves that "prominent" treatment — UITabBarController.h:
            // "…a UISearchTab that could become prominent (when
            // automaticallyActivatesSearch = true)". UISearchTab.h documents
            // that flag's default as NO, so the role alone is not enough.
            // This modifier is SwiftUI's spelling of setting it to YES.
            .tabViewSearchActivation(.searchTabSelection)
            // Tab-bar hiding in reader mode is owned by `LeafView` (the
            // only context where reader mode is meaningful). Applying
            // it here AND there would double-toggle ; the leaf-level
            // modifier propagates up the NavigationStack / TabView
            // chain reliably.
            // Tint applied right on the TabView (BEFORE the .alert/.sheet
            // modifiers below) so only the selected-tab indicator picks up
            // the accent. Placing it later in the chain would have caused
            // the alerts/sheets attached afterwards to inherit the orange
            // env and repaint their default Buttons.
            .tint(settings.accentColor)
            // Inject the Composer so deep navigation destinations
            // (ShelfView, LeafView) can flip the creation context
            // when they appear / disappear without having to be passed
            // through every NavigationLink call site.
            .environment(composer)
            .environment(tabManager)
            .environment(store)
            .simultaneousGesture(swipeUpGesture)
            // Create bubble : single glass accessory hosting the four primary
            // entry points — new leaf, new book, new shelf and an
            // overflow menu (trash + imports). Stays visible across all tabs
            // so creation is always one tap away, à la Apple Music mini-player.
            // Hidden in reader mode (PRO-59) and, per PRO-60, when the
            // user is not at the library root. Toggleable in Settings →
            // Create bubble.
            //
            // **Use the official `isEnabled:` overload, NOT a custom helper.**
            // SwiftUI ships two overloads of `tabViewBottomAccessory` —
            // one without `isEnabled` and one with — both at the same type
            // signature. The `isEnabled` overload collapses the slot
            // properly without rebuilding the TabView subtree. A previous
            // custom `tabViewBottomAccessory(when:)` helper that swapped
            // between `self.tabViewBottomAccessory{...}` and bare `self`
            // landed in SwiftUI's `_ConditionalContent` which treats the
            // branch swap as a view replacement — that tore down the
            // inner NavigationStack mid-push and dropped the user back
            // on the home view after every tap.
            .tabViewBottomAccessory(isEnabled: !readerMode.isActive && shouldShowAccessory) {
                CreateBubble(
                    onNewLeaf: { composer.openNewLeaf() },
                    onNewBook: { composer.openNewBook() },
                    onNewShelf: { composer.openNewShelf() },
                    onShowTrash: { composer.showingTrash = true },
                    onDeleteAll: { composer.showingDeleteAllConfirm = true },
                    hasItemsForDeleteAll: !store.items.isEmpty,
                    onImportNotion: { composer.showingNotionImport = true },
                    onImportBear: { composer.showingBearImport = true },
                    onImportCraftTextBundle: { composer.showingCraftTextBundleImport = true },
                    onImportCraftCombined: { composer.showingCraftCombinedImport = true },
                    onShowAllLeaves: { openSwitcher() }
                )
            }
            .modifier(ContentSheets(composer: composer, store: store, settings: settings, tabManager: tabManager))
            .modifier(ContentAlerts(composer: composer, store: store))
            .onAppear { store.connect() }
            .task { composer.bindQuickActions() }
            .errorAlert(message: $store.errorMessage, onRetry: store.load)
    }

    /// Whether the CreateBubble should render in the current context.
    /// Returns false when the user has the "Hide outside Library root"
    /// setting on (default) AND is anywhere deeper than the library
    /// home (inside a shelf / leaf / book). Always true when the user
    /// has opted out.
    private var shouldShowAccessory: Bool {
        guard settings.hidesAccessoryOutsideLibraryRoot else { return true }
        return composer.currentContext == .root
    }

    /// The discoverable escape hatch — top-right floating capsule with
    /// the `eyeglasses.slash` glyph. Tap = exit reader mode. Pairs with
    /// the multi-finger long-press for users who forget the gesture.
    private var readerExitButton: some View {
        Button { readerMode.deactivate() } label: {
            Image(systemName: "eyeglasses.slash")
                .font(.title3.weight(.regular))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        .accessibilityLabel("Exit reader mode")
    }

    // ── Root tabs ────────────────────────────────────────────────────────

    /// The 4-tab root. Extracted so the SwiftUI type-checker doesn't
    /// blow up on `body` once every `.sheet` / `.alert` modifier piles
    /// up — we hit the "unable to type-check this expression in
    /// reasonable time" wall when both were inlined.
    @ViewBuilder
    private var rootTabs: some View {
        TabView(selection: Binding(
            get: { composer.selectedTab },
            set: { newTab in
                if newTab != composer.selectedTab { Haptic.tap() }
                composer.selectedTab = newTab
            }
        )) {
            Tab("Library", systemImage: "books.vertical.fill",
                value: Composer.TabKind.leaves) {
                LibraryView(store: store)
                    // Bumping `leavesHomeKey` from outside (the
                    // switcher's ✓ when all tabs are closed)
                    // force-recreates this view with fresh @State —
                    // the only reliable way to pop a NavigationStack
                    // whose path mutation didn't take (SwiftUI bug).
                    .id(composer.leavesHomeKey)
            }
            Tab("Books", systemImage: "book.fill",
                value: Composer.TabKind.books) {
                BooksHomeView(store: store)
            }
            Tab("Inbox",
                systemImage: store.hasInboxNotification ? "tray.badge.fill" : "tray.fill",
                value: Composer.TabKind.inbox) {
                InboxView(store: store)
            }
            Tab(value: Composer.TabKind.search, role: .search) {
                SearchView(store: store)
            }
        }
    }

    // ── Swipe-up to open switcher ────────────────────────────────────────

    /// Y-coordinate threshold (from the bottom of the screen) above
    /// which a swipe starts being eligible for the "open switcher"
    /// gesture. The tab bar + accessory sit in roughly the bottom
    /// 130 pt on a typical iPhone.
    private static let swipeUpStartBand: CGFloat = 140
    /// Upward translation past this distance (pt) commits the open.
    private static let swipeUpCommitDistance: CGFloat = 70
    /// Vertical-to-horizontal ratio that disqualifies a swipe as
    /// "mostly vertical". Smaller = stricter.
    private static let swipeUpDirectionRatio: CGFloat = 1.4

    /// Swipe-up from the tab bar opens the "All leaves" switcher
    /// (Safari pattern : the bottom toolbar zone is the canonical
    /// entry into the tab grid). `simultaneousGesture` lets it coexist
    /// with tab taps (no movement = tab tap fires; movement = our
    /// drag fires).
    private var swipeUpGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .global)
            .onChanged(swipeUpProgress)
            .onEnded(commitSwipeUpIfReady)
    }

    /// True if `value` is a candidate swipe-up : started near the
    /// bottom of the screen, moving up, and the motion is dominantly
    /// vertical. Doesn't require past-threshold — that's the commit.
    private func isCandidateSwipeUp(_ value: DragGesture.Value) -> Bool {
        // `UIScreen.main` is deprecated since iOS 16 — read the active
        // window scene's screen instead. Falls back to 0 (gesture never
        // qualifies) if no scene is foreground, which is the safer
        // default than acting on a guessed height.
        let screenH = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .screen.bounds.height ?? 0
        let startedNearBottom = value.startLocation.y > screenH - Self.swipeUpStartBand
        let upward = value.translation.height < 0
        let mostlyVertical = abs(value.translation.height)
            > abs(value.translation.width) * Self.swipeUpDirectionRatio
        return startedNearBottom && upward && mostlyVertical
    }

    /// Tracks the in-flight drag — fires a single anticipation haptic
    /// when the user crosses the commit threshold so they feel "yes,
    /// release here will open the switcher" before they let go.
    private func swipeUpProgress(_ value: DragGesture.Value) {
        guard isCandidateSwipeUp(value) else {
            swipeUpHapticFired = false
            return
        }
        let crossed = value.translation.height < -Self.swipeUpCommitDistance
        if crossed && !swipeUpHapticFired {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            swipeUpHapticFired = true
        }
    }

    /// On release, commit the open if the swipe was a candidate and
    /// crossed the threshold. Resets the haptic flag either way.
    private func commitSwipeUpIfReady(_ value: DragGesture.Value) {
        defer { swipeUpHapticFired = false }
        guard isCandidateSwipeUp(value) else { return }
        if value.translation.height < -Self.swipeUpCommitDistance {
            openSwitcher()
        }
    }

    /// Centralised "open the switcher" path. Card thumbnails come from
    /// `LeafSnapshotHook`'s `viewWillDisappear` capture, not from
    /// a live grab — re-opening a doc just shows its top, which is
    /// what the user prefers over a half-restored scroll mid-page.
    private func openSwitcher() {
        composer.showingAllLeaves = true
    }
}

// ── Sheet stack ──────────────────────────────────────────────────────────────

/// Bundles every modal presentation (create-doc sheet, trash, full-screen
/// switcher, import sheets) into one modifier. Extracted from `body` for the
/// same reason as `ContentAlerts` — without it the SwiftUI type checker hits
/// the "unable to type-check in reasonable time" wall when chained on top of
/// the alerts and the tab bar accessory.
private struct ContentSheets: ViewModifier {
    @Bindable var composer: Composer
    @Bindable var store: PinkhaStore
    @Bindable var settings: AppSettings
    @Bindable var tabManager: TabManager

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $composer.showingCreateLeaf) { createDocSheet }
            .sheet(isPresented: $composer.showingTrash) {
                TrashView().environment(store)
            }
            .fullScreenCover(isPresented: $composer.showingAllLeaves) {
                AllLeavesSwitcher(store: store) { leafId in
                    composer.showingAllLeaves = false
                    composer.pendingOpenLeaf = leafId
                }
                .environment(settings)
                .environment(tabManager)
                // The switcher's `+` bottom-bar action needs `composer`
                // to trigger the create-doc sheet. `fullScreenCover`
                // doesn't always propagate env objects to its content
                // root in iOS 26 — explicit injection is required.
                .environment(composer)
            }
            .sheet(isPresented: $composer.showingNotionImport) {
                NotionImportView(api: store.api) { store.load() }
            }
            .sheet(isPresented: $composer.showingBearImport) {
                BearImportView(api: store.api) { store.load() }
            }
            .sheet(isPresented: $composer.showingCraftTextBundleImport) {
                CraftTextBundleImportView(api: store.api) { store.load() }
            }
            .sheet(isPresented: $composer.showingCraftCombinedImport) {
                CraftCombinedImportView(api: store.api) { store.load() }
            }
            // Belt-and-braces refresh : the import sheets each call
            // store.load() when the user taps Done, but they can also be
            // dismissed by a swipe-down or Cancel — paths where the
            // existing completion callback doesn't fire. We listen on each
            // `isPresented` falling edge to guarantee the home picks up
            // whatever the importer committed to SQLite before the dismiss.
            .onChange(of: composer.showingNotionImport) { _, isShowing in
                if !isShowing { store.load() }
            }
            .onChange(of: composer.showingBearImport) { _, isShowing in
                if !isShowing { store.load() }
            }
            .onChange(of: composer.showingCraftTextBundleImport) { _, isShowing in
                if !isShowing { store.load() }
            }
            .onChange(of: composer.showingCraftCombinedImport) { _, isShowing in
                if !isShowing { store.load() }
            }
    }

    /// The create-doc sheet body. The closures live inside the modifier so
    /// `composer` and `store` are captured without re-passing them.
    @ViewBuilder
    private var createDocSheet: some View {
        CreateLeafSheet(
            title: $composer.newTitle,
            prompt: composer.createMode == .leaf ? "Leaf title" : "Book title",
            navigationTitle: composer.createMode == .leaf ? "New Leaf" : "New Book",
            // Only the Leaf flow can attach to a book — the
            // Book creation flow doesn't make sense to nest
            // inside another DB.
            availableBooks: composer.createMode == .leaf ? store.books : [],
            api: composer.createMode == .leaf ? store.api : nil
        ) { bookId, propertyValues, standaloneStyle in
            handleCreateCommit(bookId: bookId,
                               propertyValues: propertyValues,
                               standaloneStyle: standaloneStyle)
        } onCancel: {
            composer.newTitle = ""
            composer.showingCreateLeaf = false
        }
    }

    private func handleCreateCommit(
        bookId: String?,
        propertyValues: [String: PropertyValueFfi],
        standaloneStyle: StandaloneStyle
    ) {
        switch composer.createMode {
        case .leaf:
            let newId: String?
            if let bookId = bookId {
                // User opted to file the leaf as a row of an
                // existing book — the store handles both the
                // doc creation AND the entry insert. We still
                // propagate the chosen style so the doc carries its
                // cover / icon / theme when opened from the DB.
                newId = store.createLeafInBook(
                    title: composer.newTitle,
                    bookId: bookId,
                    propertyValues: propertyValues,
                    style: standaloneStyle
                )
            } else {
                newId = store.createLeaf(title: composer.newTitle,
                                         in: composer.currentContext,
                                         style: standaloneStyle)
            }
            switch (composer.currentContext, newId) {
            case (.leaf(let parentId), let id?):
                // For `.leaf` context, the active editor's VM
                // owns the in-memory blocks. Signal it via the
                // composer so *it* performs the `addBlock` for the
                // Page reference — doing it from here behind the
                // VM's back would race with the next burst flush
                // and get overwritten.
                composer.pendingChildPage = Composer.PendingChildPage(
                    parentLeafId: parentId,
                    childLeafId: id
                )
            case (.book, _):
                // Inside a book : we just inserted a new row. Stay on
                // the BookView so the user sees the row land in the
                // table — opening the editor would queue a Library-
                // side push that only fires on tab switch (only
                // LibraryView consumes `pendingOpenLeaf`).
                break
            case (.root, let id?), (.shelf, let id?):
                // Open the doc right after the sheet dismisses so
                // the user lands in the editor (Apple Notes / Bear
                // pattern).
                composer.pendingOpenLeaf = id
            default:
                break
            }
        case .book:
            store.createBook(title: composer.newTitle, in: composer.currentContext)
        }
        composer.newTitle = ""
        composer.showingCreateLeaf = false
    }
}

// ── Alert stack ──────────────────────────────────────────────────────────────

/// Bundles the three top-level alerts (new shelf, delete-all step 1,
/// delete-all step 2) into a single modifier so the SwiftUI type-checker
/// can chew through `body` — inlining the alerts on top of every `.sheet`
/// / `.fullScreenCover` already stacked there blew the "unable to
/// type-check in reasonable time" budget.
private struct ContentAlerts: ViewModifier {
    @Bindable var composer: Composer
    @Bindable var store: PinkhaStore

    func body(content: Content) -> some View {
        content
            .alert("New Shelf", isPresented: $composer.showingNewShelf) {
                TextField("Name", text: $composer.newShelfName)
                Button("Create") {
                    let trimmed = composer.newShelfName
                        .trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    store.createShelf(name: trimmed, in: composer.currentContext)
                    composer.newShelfName = ""
                }
                Button("Cancel", role: .cancel) { composer.newShelfName = "" }
            }
            .alert("Delete all \(store.items.count) leaves?",
                   isPresented: $composer.showingDeleteAllConfirm) {
                Button("Delete All", role: .destructive) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        composer.showingDeleteAllConfirm2 = true
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all your leaves.")
            }
            .alert("Are you sure?", isPresented: $composer.showingDeleteAllConfirm2) {
                Button("Yes, delete everything", role: .destructive) {
                    store.deleteAll()
                    store.deleteAllBooks()
                    store.deleteAllShelves()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
    }
}

// ── Preview ───────────────────────────────────────────────────────────────────

#if DEBUG
/// Single root preview that mirrors `PinkhaApp.body` — wraps the
/// whole app so the Xcode Canvas can iterate on it without a full
/// build/install round-trip. Leaf that the iOS 26 `TabView` chrome
/// (tab bar + bottom accessory) and any layout that depends on it
/// still need a simulator/device to render properly; the Canvas is
/// best for in-view edits (typography, spacing inside content, etc.).
#Preview {
    ContentView()
        .environment(AppSettings())
        .tint(AppSettings().accentColor)
}
#endif
