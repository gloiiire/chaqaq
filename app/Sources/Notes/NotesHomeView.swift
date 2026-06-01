import SwiftUI

// ── Tab 1: Notes (unified workspace) ──────────────────────────────────────────

/// Home screen for the Notes tab — shows notes and databases in a unified list.
struct NotesHomeView: View {
    @ObservedObject var store: PinkhaStore
    @State private var showingCreate = false
    @State private var showingImport = false
    @State private var showingBearImport = false
    @State private var showingCraftImport = false
    @State private var showingCraftTextBundleImport = false
    @State private var showingDeleteAllConfirm = false
    @State private var newTitle = ""
    @State private var createMode: CreateMode = .note

    enum CreateMode { case note, database }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                List {
                    // ── Recent strip (only when items exist) ──────────────
                    if !store.items.isEmpty {
                        Section {
                            RecentStrip(items: store.recentItems, api: store.api) {
                                store.load()
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                        } header: {
                            SectionHeader(title: "Recent")
                        }
                    }

                    // ── All items ─────────────────────────────────────────
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
                                }
                                .onDelete { indexSet in
                                    for i in indexSet {
                                        let item = store.items[i]
                                        switch item {
                                        case .note(let d):      store.delete(id: d.id)
                                        case .database(let db): store.deleteDatabase(id: db.id)
                                        }
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
                .navigationTitle(greeting)
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if !store.items.isEmpty {
                            Button(role: .destructive) {
                                showingDeleteAllConfirm = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .confirmationDialog("Delete all \(store.items.count) notes?",
                                               isPresented: $showingDeleteAllConfirm,
                                               titleVisibility: .visible) {
                                Button("Delete All", role: .destructive) { store.deleteAll() }
                                Button("Cancel", role: .cancel) {}
                            }
                        }
                    }
                }

                // ── FAB ───────────────────────────────────────────────────
                Menu {
                    Button {
                        createMode = .note
                        newTitle = ""
                        showingCreate = true
                    } label: {
                        Label("New note", systemImage: "doc.text")
                    }
                    Button {
                        createMode = .database
                        newTitle = ""
                        showingCreate = true
                    } label: {
                        Label("New database", systemImage: "tablecells")
                    }
                    Divider()
                    Button {
                        showingImport = true
                    } label: {
                        Label("Import from Notion", systemImage: "arrow.down.doc")
                    }
                    Button {
                        showingBearImport = true
                    } label: {
                        Label("Import from Bear", systemImage: "pencil.and.list.clipboard")
                    }
                    Button {
                        showingCraftImport = true
                    } label: {
                        Label("Import from Craft", systemImage: "books.vertical")
                    }
                    Button {
                        showingCraftTextBundleImport = true
                    } label: {
                        Label("Import from Craft (TextBundle)", systemImage: "doc.zipper")
                    }
                } label: {
                    FloatingButton(icon: "square.and.pencil") {}
                }
                .accessibilityIdentifier("createFAB")
                .padding(.trailing, 24)
                .padding(.bottom, 32)
            }
            .sheet(isPresented: $showingImport) {
                NotionImportView(api: store.api) {
                    store.load()
                }
            }
            .sheet(isPresented: $showingBearImport) {
                BearImportView(api: store.api) {
                    store.load()
                }
            }
            .sheet(isPresented: $showingCraftImport) {
                CraftImportView(api: store.api) {
                    store.load()
                }
            }
            .sheet(isPresented: $showingCraftTextBundleImport) {
                CraftTextBundleImportView(api: store.api) {
                    store.load()
                }
            }
            .sheet(isPresented: $showingCreate) {
                CreateDocumentSheet(
                    title: $newTitle,
                    prompt: createMode == .note ? "Note title" : "Database title"
                ) {
                    switch createMode {
                    case .note:     store.create(title: newTitle)
                    case .database: store.createDatabase(title: newTitle)
                    }
                    newTitle = ""
                    showingCreate = false
                } onCancel: {
                    newTitle = ""
                    showingCreate = false
                }
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
        case .database(let db):
            NavigationLink(destination: DatabaseView(dbId: db.id, api: api)) {
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

// ── Recent strip ──────────────────────────────────────────────────────────────

/// Horizontal scroll strip displaying the most recently updated workspace items.
struct RecentStrip: View {
    let items: [WorkspaceItem]
    let api: PinkhaApi?
    let onDisappear: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    if let api {
                        switch item {
                        case .note(let doc):
                            NavigationLink(destination: DocumentView(docId: doc.id, api: api,
                                                                     onDisappear: onDisappear)) {
                                RecentCard(item: item)
                            }
                            .buttonStyle(.plain)
                        case .database(let db):
                            NavigationLink(destination: DatabaseView(dbId: db.id, api: api)) {
                                RecentCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
    }
}

/// A card in the recent strip — displays icon, title, and relative date.
struct RecentCard: View {
    let item: WorkspaceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            itemIcon.frame(width: 36, height: 36)
            Spacer()
            VStack(alignment: .leading, spacing: 3) {
                Text(item.titlePlain.isEmpty ? "Untitled" : item.titlePlain)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let date = formattedDate(item.updatedAt) {
                    Text(date).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .frame(width: 150, height: 140)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    @ViewBuilder
    private var itemIcon: some View {
        switch item {
        case .note(let doc):
            if let icon = UserDefaults.standard.string(forKey: "document.icon.\(doc.id)"), !icon.isEmpty {
                Text(icon).font(.title)
            } else {
                Image(systemName: "doc.text").font(.title2).foregroundStyle(.secondary)
            }
        case .database:
            Image(systemName: "tablecells").font(.title2).foregroundStyle(.secondary)
        }
    }

    private func formattedDate(_ iso: String) -> String? {
        guard !iso.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
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
            if let icon = UserDefaults.standard.string(forKey: "document.icon.\(doc.id)"), !icon.isEmpty {
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
