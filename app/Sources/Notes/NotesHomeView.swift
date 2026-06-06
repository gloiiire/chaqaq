import SwiftUI

// ── Tab 1: Notes (unified workspace) ──────────────────────────────────────────

/// Home screen for the Notes tab — shows notes and databases in a unified list.
/// All creation / import / trash actions live in the global CreateBubble
/// hosted by `ContentView.tabViewBottomAccessory`, so this view focuses on
/// presenting the workspace content.
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

    /// Returns a greeting adapted to the time of day.
    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        switch h {
        case 5..<12: return "Good morning."
        case 12..<18: return "Good afternoon."
        default:      return "Good evening."
        }
    }
}

// ── Long-press preview card ───────────────────────────────────────────────────

/// Apple-Music-style floating card shown when the user long-presses
/// a note row. Larger, more deliberate than the list row — the title
/// reads loud, the icon anchors the eye. Sits over a frosted
/// background while the contextMenu's actions slide up underneath.
private struct NoteCardPreview: View {
    let doc: DocumentMetaFfi

    private let iconSize: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover image (or fallback gradient) on top, exactly
            // like the RecentCard pattern — Notion-style framing.
            CoverImageView(cover: doc.cover)
                .frame(height: 140)
                .clipped()

            VStack(alignment: .leading, spacing: 6) {
                Text(doc.titlePlain.isEmpty ? "Untitled" : doc.titlePlain)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let date = formattedRelativeDate(doc.updatedAt) {
                    Text(date)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.top, iconSize / 2 + 10)
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                // Icon overlapping the cover/content boundary,
                // matching the RecentCard treatment.
                Group {
                    if let icon = doc.icon, !icon.isEmpty {
                        Text(icon).font(.system(size: 30))
                    } else {
                        Image(systemName: "doc.text")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: iconSize, height: iconSize)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
                .padding(.leading, 16)
                .offset(y: -iconSize / 2)
            }
        }
        .frame(width: 240)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
}

// ── Recent strip ──────────────────────────────────────────────────────────────

/// Horizontal scroll strip displaying the most recently updated workspace items.
struct RecentStrip: View {
    let items: [WorkspaceItem]
    let api: PinkhaApi?
    let onDisappear: () -> Void
    /// Programmatic-push handler for note items — wired from the
    /// parent so each card can use a `Button` instead of
    /// `NavigationLink`. iOS 26 has a confirmed bug where multiple
    /// `NavigationLink + .contextMenu` rows inside a horizontal
    /// `ScrollView` only register the long-press on the first row.
    let onOpenNote: (String) -> Void
    var onRenameNote: ((DocumentMetaFfi) -> Void)? = nil
    var onDeleteNote: ((DocumentMetaFfi) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    if let api {
                        switch item {
                        case .note(let doc):
                            RecentNoteCard(
                                item: item,
                                doc: doc,
                                onOpen: { onOpenNote(doc.id) },
                                onRename: { onRenameNote?(doc) },
                                onDelete: { onDeleteNote?(doc) }
                            )
                            .id(doc.id)
                        case .database(let db):
                            NavigationLink(destination: DatabaseView(dbId: db.id, api: api,
                                                                    onDisappear: onDisappear)) {
                                RecentCard(item: item)
                            }
                            .buttonStyle(.plain)
                            .id(db.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
    }
}

/// Per-item wrapper so each card owns an independent `Button` +
/// `.contextMenu` registration. Pulling this out of `RecentStrip`'s
/// body fixed the "long-press lifts the whole strip as one" bug on
/// iOS 26 — SwiftUI registers the gesture recogniser per dedicated
/// View struct, not per `ForEach` iteration of an inline expression.
private struct RecentNoteCard: View {
    let item: WorkspaceItem
    let doc: DocumentMetaFfi
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        // UIKit-backed context menu — SwiftUI's `.contextMenu` has a
        // confirmed iOS 26 bug inside horizontal `ScrollView` where
        // it only registers on the first row. UIKit's
        // `UIContextMenuInteraction` (which Apple Music uses for the
        // same UX) doesn't have that quirk.
        UIKitContextMenu(
            content: { RecentCard(item: item) },
            preview: { NoteCardPreview(doc: doc) },
            menu: {
                let rename = UIAction(
                    title: "Rename",
                    image: UIImage(systemName: "pencil"),
                    handler: { _ in onRename() }
                )
                let delete = UIAction(
                    title: "Delete",
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive,
                    handler: { _ in onDelete() }
                )
                return UIMenu(children: [rename, delete])
            },
            onTapPreview: onOpen
        )
        .frame(width: 165, height: 170)
        .onTapGesture(perform: onOpen)
    }
}

/// A card in the recent strip — Notion-style with a cover image
/// (or fallback gradient) filling the top half, an icon overlapping the
/// cover/content boundary, and the title plus relative date below.
struct RecentCard: View {
    let item: WorkspaceItem

    private let cornerRadius: CGFloat = 16
    private let coverHeight: CGFloat = 80
    private let iconSize: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverImageView(cover: coverValue)
                .frame(height: coverHeight)
                .clipped()
            // The bottom block hosts both the overlapping icon and the
            // title/date stack. The icon is placed in an overlay so it
            // can sit half on top of the cover and half on the white
            // surface below — same trick Notion uses.
            VStack(alignment: .leading, spacing: 3) {
                Text(item.titlePlain.isEmpty ? "Untitled" : item.titlePlain)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let date = formattedDate(item.updatedAt) {
                    Text(date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            // The padding top makes room for the icon that will overlap
            // from above via the overlay below.
            .padding(.top, iconSize / 2 + 6)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                itemIcon
                    .frame(width: iconSize, height: iconSize)
                    .padding(.leading, 10)
                    .offset(y: -iconSize / 2)
            }
        }
        .frame(width: 165, height: 170, alignment: .leading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var coverValue: String? {
        if case .note(let doc) = item { return doc.cover }
        return nil
    }

    @ViewBuilder
    private var itemIcon: some View {
        switch item {
        case .note(let doc):
            if let icon = doc.icon, !icon.isEmpty {
                Text(icon).font(.title2)
            } else {
                Image(systemName: "doc.text")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: iconSize, height: iconSize)
                    .background(Color(.systemBackground), in: Circle())
                    .overlay(Circle().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            }
        case .database:
            Image(systemName: "tablecells")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: iconSize, height: iconSize)
                .background(Color(.systemBackground), in: Circle())
                .overlay(Circle().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        }
    }

    private func formattedDate(_ iso: String) -> String? {
        formattedRelativeDate(iso)
    }
}

/// Shared ISO-to-relative-date helper used by `RecentCard` and
/// `NoteCardPreview`. Kept at file scope so the preview's UIKit
/// hosting controller (in `UIKitContextMenu`) can reuse it without
/// having to instantiate the surrounding struct.
func formattedRelativeDate(_ iso: String) -> String? {
    guard !iso.isEmpty else { return nil }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = parser.date(from: iso) else { return nil }
    return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
}

/// A row in the unified workspace list.
struct WorkspaceRow: View {
    let item: WorkspaceItem

    var body: some View {
        HStack(spacing: 12) {
            itemIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(item.titlePlain.isEmpty ? "Untitled" : item.titlePlain)
                    .font(.body.weight(.medium))
                if let date = formattedDate(item.updatedAt) {
                    Text(date).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var itemIcon: some View {
        switch item {
        case .note(let doc):
            if let icon = doc.icon, !icon.isEmpty {
                Text(icon).font(.title2).frame(width: 34, height: 34)
            } else {
                Image(systemName: "doc.text")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(.secondary.opacity(0.12),
                                 in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        case .database:
            Image(systemName: "tablecells")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.secondary.opacity(0.12),
                             in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func formattedDate(_ iso: String) -> String? {
        guard !iso.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}
