import SwiftUI

// ── Tab 1: Notes (unified workspace) ──────────────────────────────────────────

/// Home screen for the Notes tab — shows notes and databases in a unified list.
/// All creation / import / trash actions live in the global CreateBubble
/// hosted by `ContentView.tabViewBottomAccessory`, so this view focuses on
/// presenting the workspace content.
struct NotesHomeView: View {
    @ObservedObject var store: PinkhaStore
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
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
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    // Override the app-level accent tint with the system
                    // label color — toolbar Buttons inherit `.tint`
                    // through the bordered/glass style, so a per-Image
                    // `.foregroundStyle` would get repainted. `.tint` on
                    // the Button is the supported escape hatch.
                    .tint(.primary)
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
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
                            NavigationLink(destination: DatabaseView(dbId: db.id, api: api,
                                                                    onDisappear: onDisappear)) {
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
