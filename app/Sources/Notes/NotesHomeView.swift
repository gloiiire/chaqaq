import SwiftUI

// ── Tab 1: Notes (unified workspace) ──────────────────────────────────────────

/// Home screen for the Notes tab — shows notes and databases in a unified list.
/// All creation / import / trash actions live in the global CreateBubble
/// hosted by `ContentView.tabViewBottomAccessory`, so this view focuses on
/// presenting the workspace content. Sibling files in this folder own the
/// recent strip (`RecentStrip.swift`) and the list row (`WorkspaceRow.swift`).
struct NotesHomeView: View {
    @ObservedObject var store: PinkhaStore
    @EnvironmentObject private var composer: Composer
    @EnvironmentObject private var settings: AppSettings
    @State private var showingSettings = false
    /// Programmatic navigation stack so a freshly-created note can be
    /// pushed onto the editor right after the create sheet dismisses
    /// — driven by `composer.pendingOpenDoc`.
    @State private var path: [String] = []
    /// Multi-select state for bulk delete. `editMode` flips between
    /// `.inactive` and `.active` via the toolbar Select button; the
    /// List binds `selection:` to `selectedIds` so the standard iOS
    /// circle UI appears next to each row when active.
    @State private var editMode: EditMode = .inactive
    @State private var selectedIds: Set<String> = []
    @State private var showingBulkDeleteConfirm = false
    /// Doc currently being renamed via the contextMenu — drives the
    /// rename alert and `renameDraft` TextField below.
    @State private var renamingDoc: DocumentMetaFfi?
    @State private var renameDraft: String = ""

    var body: some View {
        NavigationStack(path: $path) {
            // Conditional selection binding — we only let the List
            // track selection while edit mode is active. Outside of
            // it, `selectedIds` is forced to empty (writes are
            // dropped), which prevents the iOS 26 default behaviour
            // of leaving a NavigationLink-pushed row visually "focused"
            // after the user pops back.
            List(selection: Binding(
                get: { editMode == .active ? selectedIds : [] },
                set: { newValue in
                    if editMode == .active { selectedIds = newValue }
                }
            )) {
                if !store.items.isEmpty {
                    Section {
                        RecentStrip(
                            items: store.recentItems(limit: settings.recentCount),
                            api: store.api,
                            onDisappear: { store.load() },
                            onOpenNote: { docId in
                                path.append(docId)
                            },
                            onRenameNote: { doc in
                                renameDraft = doc.titlePlain
                                renamingDoc = doc
                            },
                            onDeleteNote: { doc in
                                store.delete(id: doc.id)
                            }
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                    } header: {
                        SectionHeader(title: "Recent")
                    }
                }

                if !store.listFolders().isEmpty {
                    FoldersSectionView(store: store)
                }

                if store.items.isEmpty {
                    Section {
                        NotesEmptyState()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } else {
                    Section {
                        if let api = store.api {
                            ForEach(store.items) { item in
                                itemRow(item, api: api)
                                    // Explicit swipeActions (not
                                    // `.onDelete`) so the trash icon +
                                    // label match every other swipe
                                    // delete in the app.
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            switch item {
                                            case .note(let d):      store.delete(id: d.id)
                                            case .database(let db): store.deleteDatabase(id: db.id)
                                            }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .tint(.red)
                                    }
                            }
                        } else {
                            ProgressView()
                        }
                    } header: {
                        SectionHeader(title: "All")
                    }
                }
            }
            .listStyle(.insetGrouped)
            // Re-tint the List with the accent so the edit-mode
            // selection circles stay readable. Without this they'd
            // inherit the `.tint(.primary)` set just before the
            // rename alert later in the chain and render white.
            .tint(settings.accentColor)
            .environment(\.editMode, $editMode)
            .navigationTitle(greeting)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.items.isEmpty {
                        Button(editMode == .active ? "Done" : "Select") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if editMode == .active {
                                    editMode = .inactive
                                    selectedIds.removeAll()
                                } else {
                                    editMode = .active
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if editMode == .active {
                        // In edit mode the trailing slot becomes the
                        // primary bulk-delete action. Bottom-bar
                        // placement collides with the TabView's search
                        // bubble, so we surface the action up here.
                        Button(role: .destructive) {
                            showingBulkDeleteConfirm = true
                        } label: {
                            Label(
                                selectedIds.isEmpty ? "Delete" : "Delete (\(selectedIds.count))",
                                systemImage: "trash"
                            )
                        }
                        .tint(.red)
                        .disabled(selectedIds.isEmpty)
                    } else {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        // Settings is neutral chrome — never adopts the
                        // accent that the TabView spreads through its env.
                        .tint(.primary)
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            // Native confirmation dialog before the bulk delete fires —
            // matches the Apple Notes / Mail pattern (slide-up sheet
            // anchored to the row that triggered it).
            .confirmationDialog(
                "Delete \(selectedIds.count) item\(selectedIds.count == 1 ? "" : "s")?",
                isPresented: $showingBulkDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They'll move to the trash.")
            }
            // Registered alongside the existing `NavigationLink` rows
            // so programmatic pushes via `path.append(id)` open the
            // editor — driven by `composer.pendingOpenDoc` below.
            .navigationDestination(for: String.self) { docId in
                if let api = store.api {
                    DocumentView(docId: docId, api: api, onDisappear: store.load)
                }
            }
        }
        .onChange(of: composer.pendingOpenDoc) { _, newValue in
            // Wait for the create sheet to finish dismissing before
            // pushing, otherwise SwiftUI can race the path update
            // against the sheet's exit transition and drop the push.
            guard let docId = newValue else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                path.append(docId)
                composer.pendingOpenDoc = nil
            }
        }
        .onChange(of: path) { _, newPath in
            // When the user pops back to the home, drop any selection
            // SwiftUI's List might have carried over from the programmatic
            // push — otherwise the row that was just navigated to stays
            // visually "focused" (lighter background) until the next
            // unrelated tap.
            if newPath.isEmpty && editMode != .active && !selectedIds.isEmpty {
                selectedIds.removeAll()
            }
        }
        // Rename alert — native iOS style. `.tint(.primary)` is
        // placed AFTER the `.alert` modifier so it wraps the alert
        // (env modifiers in SwiftUI flow downward to attached
        // overlays). Buttons read `.primary` instead of the
        // TabView's accent.
        .alert("Rename note", isPresented: Binding(
            get: { renamingDoc != nil },
            set: { if !$0 { renamingDoc = nil } }
        )) {
            TextField("Title", text: $renameDraft)
            Button("Rename") {
                if let doc = renamingDoc {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        store.renameDocument(id: doc.id, newTitle: trimmed)
                    }
                }
                renamingDoc = nil
            }
            Button("Cancel", role: .cancel) { renamingDoc = nil }
        }
        .tint(.primary)
        // Belt-and-braces: clear any lingering selection every time
        // the home reappears (covers pops, tab switches, sheet
        // dismissals). The onChange above only fires when `path`
        // transitions; this catches the cases where SwiftUI rebuilt
        // the home with a non-empty selection already.
        .task {
            if editMode != .active && !selectedIds.isEmpty {
                selectedIds.removeAll()
            }
        }
    }

    /// Bulk delete every selected workspace item. Routes notes through
    /// `store.delete(id:)` and databases through `deleteDatabase(id:)`
    /// so each goes via its proper SQLite soft-delete path.
    ///
    /// Important : selection is cleared BEFORE we mutate the store.
    /// UICollectionView (under SwiftUI's List) refuses to coalesce an
    /// update where the selection set still references rows that just
    /// disappeared — that's the `NSInternalInconsistencyException` we
    /// saw on Sentry (APPLE-IOS-8). Clearing first lets the diff
    /// settle on the store changes alone.
    private func deleteSelected() {
        let toDelete = store.items.filter { selectedIds.contains($0.id) }
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedIds.removeAll()
            editMode = .inactive
        }
        for item in toDelete {
            switch item {
            case .note(let d):      store.delete(id: d.id)
            case .database(let db): store.deleteDatabase(id: db.id)
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    @ViewBuilder
    private func itemRow(_ item: WorkspaceItem, api: PinkhaApi) -> some View {
        switch item {
        case .note(let doc):
            NavigationLink(destination: DocumentView(docId: doc.id, api: api,
                                                     onDisappear: store.load)) {
                WorkspaceRow(item: item)
            }
            // Apple Music-style long-press : the row floats as a
            // detached card preview, with Rename / Delete options
            // underneath. Tap on the row itself still navigates.
            .contextMenu {
                Button {
                    renameDraft = doc.titlePlain
                    renamingDoc = doc
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.primary)
                Button(role: .destructive) {
                    store.delete(id: doc.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            } preview: {
                NoteCardPreview(doc: doc)
            }
        case .database(let db):
            NavigationLink(destination: DatabaseView(dbId: db.id, api: api,
                                                    onDisappear: store.load)) {
                WorkspaceRow(item: item)
            }
        }
    }

    /// Returns a greeting adapted to the time of day. Returns
    /// `LocalizedStringKey` (not `String`) so `.navigationTitle(_:)`
    /// picks the localized overload — a raw `String` would render
    /// verbatim and skip the catalog lookup.
    private var greeting: LocalizedStringKey {
        let h = Calendar.current.component(.hour, from: .now)
        switch h {
        case 5..<12: return "Good morning."
        case 12..<18: return "Good afternoon."
        default:      return "Good evening."
        }
    }
}
