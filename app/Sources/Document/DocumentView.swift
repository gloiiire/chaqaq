import SwiftUI

// ── Vue document ──────────────────────────────────────────────────────────────

/// Éditeur de document plein écran : couverture + icône, titre, liste de blocs, FAB, pill undo/redo.
struct DocumentView: View {
    @StateObject var vm: DocumentViewModel
    @State var showingBlockPicker = false
    @State var editMode: EditMode = .inactive
    @State var focusTitle = false
    @State var titleInNavBar = false
    @State var documentLocked: Bool
    @State var documentIcon: String?
    @State var recentEmojis: [String]
    @State var selectedBlocks: Set<String> = []
    @State var keyboardVisible = false
    let lockKey: String
    let iconKey: String

    var onDisappear: (() -> Void)? = nil

    init(docId: String, api: PinkhaApi, onDisappear: (() -> Void)? = nil) {
        let lockKey = Self.lockKeyFor(docId: docId)
        let iconKey = Self.iconKeyFor(docId: docId)
        _vm = StateObject(wrappedValue: DocumentViewModel(docId: docId, api: api))
        _documentLocked = State(initialValue: UserDefaults.standard.bool(forKey: lockKey))
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

    // ── Liste principale ──────────────────────────────────────────────────────

    var documentList: some View {
        List {
            DocumentDecorView(
                cover: vm.cover, icone: documentIcon, recentEmojis: recentEmojis,
                verrouille: documentLocked,
                onCouverture: { vm.saveCover($0) },
                onImageData: { data in vm.saveCoverImage(data: data) },
                onImageFichier: { url in vm.saveCoverImageFromFile(url) },
                onIcone: { nouvelleIcone in
                    documentIcon = nouvelleIcone
                    if let nouvelleIcone {
                        UserDefaults.standard.set(nouvelleIcone, forKey: iconKey)
                        recentEmojis = saveRecentEmoji(nouvelleIcone)
                    } else {
                        UserDefaults.standard.removeObject(forKey: iconKey)
                    }
                }
            )
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets()).moveDisabled(true).deleteDisabled(true)

            DocumentTitleView(title: $vm.title, focusDemande: $focusTitle,
                              onSave: vm.saveTitle,
                              onNewBlock: { vm.addBlock(type: .text) })
                .disabled(documentLocked)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
                .moveDisabled(true).deleteDisabled(true)

            if vm.blocks.isEmpty && !documentLocked {
                EmptyEditorState { vm.addBlock(type: .text) }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .moveDisabled(true).deleteDisabled(true)
            }

            ForEach($vm.blocks) { $block in blockListRow($block) }
                .onMove(perform: vm.moveBlock)

            if !documentLocked {
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
        .onAppear { vm.load() }
        .onDisappear { vm.flushAllBursts(); vm.saveTitle(); onDisappear?() }
        .sheet(isPresented: $showingBlockPicker) {
            BlockPickerSheet { type in vm.addBlock(type: type, afterId: vm.activeBlockId) }
        }
        .alert("Erreur", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
    }

    // ── Sélection / helpers ───────────────────────────────────────────────────

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
        guard !documentLocked else { return }
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
