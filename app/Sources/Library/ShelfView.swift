import SwiftUI
import PinkhaFFI
import PinkhaCore
import PinkhaDesignSystem
import PinkhaComposer
import LeafFeature

// ── Shelf content view ───────────────────────────────────────────────────────

/// Shows the contents of a single shelf: its sub-shelves (Craft-style nesting)
/// then its leaves. Tapping a sub-shelf pushes another `ShelfView` onto
/// the same NavigationStack, giving arbitrary-depth navigation for free.
struct ShelfView: View {
    @Bindable var store: PinkhaStore
    let shelf: ShelfMetaFfi
    /// Optional Composer — injected by `ContentView`. We read it to flip
    /// `currentContext` to this shelf on appear and back to `.root` on
    /// disappear, so the create bubble's "New …" land inside the shelf
    /// the user is looking at.
    @Environment(Composer.self) private var composer
    @Environment(TabManager.self) private var tabManager

    @State private var showingNewSubShelf = false
    @State private var newSubShelfName = ""
    @State private var showingRename = false
    @State private var renameDraft = ""
    @State private var showingEmojiPicker = false
    @State private var recentEmojis: [String] = loadRecentEmojis()

    /// Most up-to-date copy of `shelf` so a rename / icon update reflects
    /// without popping back to the parent view. Re-derived from the store
    /// on each render — `store.listShelves()` is cheap (in-memory cache).
    private var current: ShelfMetaFfi {
        store.listShelves().first(where: { $0.id == shelf.id }) ?? shelf
    }

    var body: some View {
        let subShelves = store.childShelves(of: shelf.id)
        let docs = store.documentsInShelf(shelfId: shelf.id)

        List {
            // ── Sub-shelves ───────────────────────────────────────────────
            Section {
                ForEach(subShelves, id: \.id) { sub in
                    NavigationLink(destination: ShelfView(store: store, shelf: sub)) {
                        ShelfRow(shelf: sub)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.deleteShelf(id: sub.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }

                Button {
                    newSubShelfName = ""
                    showingNewSubShelf = true
                } label: {
                    Label("New sub-shelf", systemImage: "shelf.badge.plus")
                        .foregroundStyle(.tint)
                }
            } header: {
                SectionHeader(title: "Shelves")
            }

            // ── Leaves ─────────────────────────────────────────────────
            Section {
                if docs.isEmpty {
                    Text("No notes in this shelf yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else if let api = store.api {
                    ForEach(docs, id: \.id) { doc in
                        NavigationLink(destination: LeafView(vm: tabManager.open(leafId: doc.id, api: api),
                                                                  onDisappear: store.load)) {
                            LibraryRow(item: .note(doc))
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.delete(id: doc.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
            } header: {
                SectionHeader(title: "Notes")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Overflow menu : rename, set/clear icon. The icon picker
            // re-uses the same EmojiPickerSheet as leaves so the
            // experience stays consistent across the library.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingEmojiPicker = true
                    } label: {
                        Label(current.icon == nil ? "Set icon" : "Change icon",
                              systemImage: "face.smiling")
                    }
                    if current.icon != nil {
                        Button(role: .destructive) {
                            store.updateShelfIcon(id: shelf.id, icon: nil)
                        } label: {
                            Label("Remove icon", systemImage: "trash")
                        }
                    }
                    Divider()
                    Button {
                        renameDraft = current.name
                        showingRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More actions")
            }
        }
        .onAppear { composer.currentContext = .shelf(id: shelf.id) }
        .onDisappear {
            // Same guard as LeafView.onDisappear : SwiftUI may
            // fire the destination's onAppear before our onDisappear,
            // so we only reset when the context is still ours.
            if composer.currentContext == .shelf(id: shelf.id) {
                composer.currentContext = .root
            }
        }
        .alert("New sub-shelf", isPresented: $showingNewSubShelf) {
            TextField("Name", text: $newSubShelfName)
            Button("Create") {
                let trimmed = newSubShelfName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                store.createShelf(name: trimmed, parentId: shelf.id)
                store.load()
                newSubShelfName = ""
            }
            Button("Cancel", role: .cancel) { newSubShelfName = "" }
        }
        .alert("Rename shelf", isPresented: $showingRename) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                store.renameShelf(id: shelf.id, newName: trimmed)
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingEmojiPicker) {
            EmojiPickerSheet(selection: current.icon, recents: recentEmojis) { emoji in
                store.updateShelfIcon(id: shelf.id, icon: emoji)
                recentEmojis = saveRecentEmoji(emoji)
                showingEmojiPicker = false
            }
        }
    }

    /// Prepends the emoji to the navigation title when set, so the user
    /// sees their chosen icon at the top of the shelf view too.
    private var displayTitle: String {
        if let icon = current.icon, !icon.isEmpty {
            return "\(icon)  \(current.name)"
        }
        return current.name
    }
}

// ── Shelf row ────────────────────────────────────────────────────────────────

/// Row used by both `ShelfView` (sub-shelves) and `ShelvesSectionView`
/// (root-level shelves) — shows the emoji icon when set, falling back to
/// the system shelf symbol otherwise.
struct ShelfRow: View {
    let shelf: ShelfMetaFfi

    var body: some View {
        HStack(spacing: 12) {
            if let icon = shelf.icon, !icon.isEmpty {
                Text(icon).font(.title3).frame(width: 28)
            } else {
                Image(systemName: "shelf").foregroundStyle(.tint).frame(width: 28)
            }
            Text(shelf.name)
        }
    }
}

// ── Shelves section ───────────────────────────────────────────────────────────

/// Section that lists top-level shelves in `LibraryView`.
struct ShelvesSectionView: View {
    @Bindable var store: PinkhaStore
    @State private var showingNewShelf = false
    @State private var newShelfName = ""

    var body: some View {
        let shelves = store.childShelves(of: nil)
        Section {
            ForEach(shelves, id: \.id) { shelf in
                NavigationLink(destination: ShelfView(store: store, shelf: shelf)) {
                    ShelfRow(shelf: shelf)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.deleteShelf(id: shelf.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }

            Button {
                showingNewShelf = true
            } label: {
                Label("New Shelf", systemImage: "shelf.badge.plus")
                    .foregroundStyle(.tint)
            }
        } header: {
            SectionHeader(title: "Shelves")
        }
        .alert("New Shelf", isPresented: $showingNewShelf) {
            TextField("Name", text: $newShelfName)
            Button("Create") {
                guard !newShelfName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                store.createShelf(name: newShelfName)
                newShelfName = ""
            }
            Button("Cancel", role: .cancel) { newShelfName = "" }
        }
    }
}
