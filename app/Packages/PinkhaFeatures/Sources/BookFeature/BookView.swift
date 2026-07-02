import SwiftUI
import PinkhaFFI
import PinkhaCore
import PinkhaComposer
import PinkhaDesignSystem
import LeafFeature

/// Orchestrates the full book screen :
///   1. Scrollable doc-like header (cover + icon + title + description).
///   2. Sticky toolbar (view picker / search / filter / properties / +).
///   3. Active body component picked by the active view's `ViewTypeFfi`.
///
/// The chrome (nav title, back chevron, error alert) lives here ;
/// the body components only render rows/cards/calendars/etc.
public struct BookView: View {
    @State private var vm: BookViewModel
    let api: PinkhaApi
    var onDisappear: (() -> Void)? = nil

    @Environment(AppSettings.self) private var settings
    @Environment(TabManager.self) private var tabManager
    @Environment(Composer.self) private var composer
    @State private var searchVisible = false
    @State private var recentEmojis: [String] = []

    public init(bookId: String, api: PinkhaApi, onDisappear: (() -> Void)? = nil) {
        _vm = State(wrappedValue: BookViewModel(bookId: bookId, api: api))
        self.api = api
        self.onDisappear = onDisappear
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                BookHeaderView(vm: vm, recentEmojis: recentEmojis)
                Section {
                    body(for: vm.activeView?.type ?? .list)
                } header: {
                    BookToolbarView(vm: vm, searchVisible: $searchVisible)
                        // `.bar` (not `.glassEffect`) is deliberate : this is a
                        // full-width pinned header, and the toolbar's search
                        // field already carries its own glass. Liquid Glass is
                        // a floating-controls treatment — stacking glass on
                        // glass is explicitly discouraged, and edge-to-edge
                        // pinned surfaces use the bar material system-wide.
                        .background(.bar)
                }
            }
        }
        // Dim base behind the cards so each row's
        // `.secondarySystemGroupedBackground` reads as elevated,
        // matching the inset-grouped vocabulary of `LibraryView`.
        .background(Color(.systemGroupedBackground))
        .scrollContentBackground(.hidden)
        // Mirror the leaf treatment : when a cover is present, let
        // the scroll content extend behind the status bar / nav-bar so
        // the cover bleeds edge-to-edge to the top of the screen and
        // the nav controls float on glass over the image. Falls back
        // to a normal inset layout when there's no cover.
        .ignoresSafeArea(.container, edges: vm.cover == nil ? [] : .top)
        // Empty nav-title — the H1 lives inside the doc-like header,
        // matching the leaf behaviour. The back button + any
        // overflow stays available in the toolbar slot.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // Adaptive glass background re-vibrancies the nav-bar over
        // whatever surface scrolls beneath it (cover image vs body).
        .toolbarBackground(.automatic, for: .navigationBar)
        // Lock toggle lives in the nav-bar trailing slot — same
        // surface as the leaf lock so users get the same gesture
        // pattern end-to-end. iOS 26 visually groups it with the back
        // chevron into the glass capsule.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                LockToolbarButton(
                    locked: vm.locked,
                    accent: settings.accentColor
                ) {
                    Haptic.toggle()
                    vm.toggleLock()
                }
            }
        }
        .onAppear {
            vm.load()
            // Track the open so the Library home Recent strip surfaces
            // recently-visited books alongside docs. MRU-only push
            // — no phantom leaf tab is created, the DB stays
            // identifiable as a book in `WorkspaceItem`.
            tabManager.markRecentlyViewed(id: vm.bookId)
            // Tells the create bubble "you're inside a book" so the
            // next "New leaf" tap lands as a row of THIS book instead
            // of a loose leaf at the library root.
            composer.currentContext = .book(id: vm.bookId)
        }
        .onDisappear {
            onDisappear?()
            // Only flip back to root when WE are the current owner —
            // a deeper pushed leaf may have overridden the context
            // before we disappear, and we don't want to stomp it.
            if composer.currentContext == .book(id: vm.bookId) {
                composer.currentContext = .root
            }
        }
        .errorAlert(message: $vm.errorMessage, onRetry: vm.load)
    }

    @ViewBuilder
    private func body(for type: ViewTypeFfi) -> some View {
        switch type {
        case .list:
            BookListView(vm: vm, api: api, onDisappear: vm.load)
        case .table:
            BookTableView(vm: vm, api: api, onDisappear: vm.load)
                .frame(minHeight: 400)
        case .kanban:
            BookBoardView(vm: vm, api: api, onDisappear: vm.load)
        case .calendar:
            BookCalendarView(vm: vm, api: api, onDisappear: vm.load)
        case .gallery:
            BookGalleryView(vm: vm, api: api, onDisappear: vm.load)
        }
    }
}
