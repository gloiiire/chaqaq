import SwiftUI

// ── Document view ─────────────────────────────────────────────────────────────

/// Full-screen document editor: cover + icon, title, block list, FAB, undo/redo pill.
struct DocumentView: View {
    @StateObject var vm: DocumentViewModel
    @State var showingBlockPicker = false
    @State var editMode: EditMode = .inactive
    @State var focusTitle = false
    @State var titleFocusOffset: Int? = nil
    @State var titleInNavBar = false
    @State var documentIcon: String?
    @State var recentEmojis: [String]
    @State var selectedBlocks: Set<String> = []
    @State var keyboardVisible = false
    /// Set when the user taps a `pinkha://doc/{uuid}` link inside the
    /// editor. The `navigationDestination` below pushes a new
    /// `DocumentView` whenever this becomes non-nil — the mention link
    /// resolves to an internal navigation rather than an external URL open.
    @State var pushedDocId: String? = nil
    /// Legacy UserDefaults key for the lock state, retained for the one-shot
    /// migration in `onAppear` — the canonical store is now `vm.locked`.
    let lockKey: String
    let iconKey: String

    var onDisappear: (() -> Void)? = nil

    init(docId: String, api: PinkhaApi, onDisappear: (() -> Void)? = nil) {
        let lockKey = Self.lockKeyFor(docId: docId)
        let iconKey = Self.iconKeyFor(docId: docId)
        _vm = StateObject(wrappedValue: DocumentViewModel(docId: docId, api: api))
        _documentIcon = State(initialValue: UserDefaults.standard.string(forKey: iconKey))
        _recentEmojis = State(initialValue: loadRecentEmojis())
        self.lockKey = lockKey
        self.iconKey = iconKey
        self.onDisappear = onDisappear
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            documentList
            overlayButtons
        }
    }

    // ── Main list ────────────────────────────────────────────────────────────

    var documentList: some View {
        List {
            DocumentDecorView(
                cover: vm.cover, icone: vm.icon, recentEmojis: recentEmojis,
                verrouille: vm.locked,
                onCouverture: { vm.saveCover($0) },
                onImageData: { data in vm.saveCoverImage(data: data) },
                onImageFichier: { url in vm.saveCoverImageFromFile(url) },
                onIcone: { nouvelleIcone in
                    // The icon is now persisted in the Rust document via the
                    // FFI — same model as the cover. The legacy UserDefaults
                    // fallback is kept for newly-typed emojis (we still track
                    // the "recently used" list in UserDefaults) but the
                    // canonical store is SQLite.
                    vm.saveIcon(nouvelleIcone)
                    if let nouvelleIcone {
                        recentEmojis = saveRecentEmoji(nouvelleIcone)
                    }
                }
            )
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets()).moveDisabled(true).deleteDisabled(true)

            DocumentTitleView(title: $vm.title, focusDemande: $focusTitle,
                              focusCursorOffset: $titleFocusOffset,
                              onSave: vm.saveTitle,
                              onNewBlock: { tail in
                                  let spans = tail.isEmpty ? [] : [InlineTextFfi(content: tail, styles: [])]
                                  vm.addBlock(type: .text, initialSpans: spans, atStart: true)
                              })
                .disabled(vm.locked)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
                .moveDisabled(true).deleteDisabled(true)

            if vm.blocks.isEmpty && !vm.locked {
                EmptyEditorState { vm.addBlock(type: .text) }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .moveDisabled(true).deleteDisabled(true)
            }

            ForEach($vm.blocks) { $block in blockListRow($block) }
                .onMove(perform: vm.moveBlock)

            if !vm.locked {
                AddBlockButton { showingBlockPicker = true }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 40, trailing: 20))
                    .moveDisabled(true).deleteDisabled(true)
            }
        }
        .listStyle(.plain)
        .ignoresSafeArea(.container, edges: vm.cover == nil ? [] : .top)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, offset in
            withAnimation(.easeInOut(duration: 0.15)) { titleInNavBar = offset > 60 }
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.editMode, $editMode)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(vm.cover == nil ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(vm.cover == nil ? nil : .dark, for: .navigationBar)
        .toolbar { documentToolbar }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { keyboardVisible = false }
        }
        .onAppear {
            vm.load()
            // One-shot migration: documents created before the icon moved
            // to the Rust domain stored their emoji in UserDefaults. Carry
            // it over to the freshly-loaded document, then clear the legacy
            // entry so the migration runs at most once per doc.
            if vm.icon == nil,
               let legacy = UserDefaults.standard.string(forKey: iconKey) {
                vm.saveIcon(legacy)
                UserDefaults.standard.removeObject(forKey: iconKey)
            }
            // Same migration for the lock flag — was in UserDefaults, now
            // lives on Document.locked. Only migrate when the loaded doc is
            // NOT already locked (avoids clobbering imports which default to
            // locked = true on the Rust side).
            if !vm.locked, UserDefaults.standard.object(forKey: lockKey) != nil {
                let legacyLocked = UserDefaults.standard.bool(forKey: lockKey)
                if legacyLocked { vm.saveLocked(true) }
                UserDefaults.standard.removeObject(forKey: lockKey)
            }
        }
        .onDisappear { vm.flushAllBursts(); vm.saveTitle(); onDisappear?() }
        .sheet(isPresented: $showingBlockPicker) {
            BlockPickerSheet { type in vm.addBlock(type: type, afterId: vm.activeBlockId) }
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
        // Internal-link navigation: tapping a `pinkha://doc/{uuid}` link in
        // a block pushes a fresh DocumentView onto the same NavigationStack.
        // The destination view runs through `onAppear { vm.load() }`, so the
        // target document loads from SQLite without any extra plumbing.
        .navigationDestination(item: $pushedDocId) { docId in
            DocumentView(docId: docId, api: vm.api, onDisappear: nil)
        }
    }

    // ── Selection / helpers ───────────────────────────────────────────────────

    func selectionButton(_ id: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { toggleSelection(id) }
        } label: {
            Image(systemName: selectedBlocks.contains(id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selectedBlocks.contains(id) ? Color("SelectionTint") : .secondary)
                .frame(width: 28, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func toggleSelection(_ id: String) {
        if selectedBlocks.contains(id) { selectedBlocks.remove(id) } else { selectedBlocks.insert(id) }
    }

    func selectFromLongPress(_ id: String) {
        guard !vm.locked else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            editMode = .active; selectedBlocks.insert(id)
            focusTitle = false; vm.stopNavigationRepeat()
        }
    }

    func deleteSelectedBlocks() {
        let ids = selectedBlocks
        withAnimation(.easeInOut(duration: 0.18)) { selectedBlocks.removeAll(); vm.deleteBlocks(ids: ids) }
    }

    static func lockKeyFor(docId: String) -> String { "document.locked.\(docId)" }
    static func iconKeyFor(docId: String) -> String { "document.icon.\(docId)" }
}
