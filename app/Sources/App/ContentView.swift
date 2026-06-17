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
    @Environment(AppSettings.self) private var settings

    /// Tracks crossing of the swipe-up haptic threshold so we fire
    /// the "ready to commit" tap exactly once per drag, not on every
    /// pixel past the line.
    @State private var swipeUpHapticFired = false

    var body: some View {
        rootTabs
            // iOS 26 tab-bar morphing : the tab bar collapses when the user
            // scrolls down so the content gets more breathing room, and
            // reappears on scroll-up. Search (role: .search) automatically
            // detaches into its own glass bubble on the right.
            .tabBarMinimizeBehavior(.onScrollDown)
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
            .tabViewBottomAccessory {
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
                    onShowAllDocs: { openSwitcher() }
                )
            }
            .modifier(ContentSheets(composer: composer, store: store, settings: settings, tabManager: tabManager))
            .modifier(ContentAlerts(composer: composer, store: store))
            .onAppear { store.connect() }
            .task { composer.bindQuickActions() }
            .errorAlert(message: $store.errorMessage, onRetry: store.load)
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
        composer.showingAllDocs = true
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
            .sheet(isPresented: $composer.showingCreateDoc) { createDocSheet }
            .sheet(isPresented: $composer.showingTrash) {
                TrashView().environment(store)
            }
            .fullScreenCover(isPresented: $composer.showingAllDocs) {
                AllLeavesSwitcher(store: store) { leafId in
                    composer.showingAllDocs = false
                    composer.pendingOpenDoc = leafId
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
            composer.showingCreateDoc = false
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
            if case .leaf(let parentId) = composer.currentContext, let newId {
                // For `.leaf` context, the active editor's VM
                // owns the in-memory blocks. Signal it via the
                // composer so *it* performs the `addBlock` for the
                // Page reference — doing it from here behind the
                // VM's back would race with the next burst flush
                // and get overwritten.
                composer.pendingChildPage = Composer.PendingChildPage(
                    parentLeafId: parentId,
                    childLeafId: newId
                )
            } else if let newId {
                // Root or shelf context — open the doc right after
                // the sheet dismisses so the user lands in the
                // editor (Apple Leafs / Bear pattern).
                composer.pendingOpenDoc = newId
            }
        case .book:
            store.createBook(title: composer.newTitle, in: composer.currentContext)
        }
        composer.newTitle = ""
        composer.showingCreateDoc = false
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
