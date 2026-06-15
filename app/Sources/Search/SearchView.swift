import SwiftUI
import PinkhaFFI

// ── Search tab ────────────────────────────────────────────────────────────────

/// Search tab — full-workspace super search. Hits four axes in parallel
/// (note titles, note content, database titles, folder names) and groups
/// the matches in sections. Each section is hidden when empty.
struct SearchView: View {
    @Bindable var store: PinkhaStore
    @Environment(AppSettings.self) private var settings
    @Environment(TabManager.self) private var tabManager
    @State private var query = ""

    private var results: PinkhaStore.SuperSearchResults {
        query.isEmpty ? .empty : store.superSearch(query: query)
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Label("Type to search", systemImage: "text.magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.top, 32)
                } else if results.isEmpty {
                    Text("No results for \"\(query)\"")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.top, 32)
                } else if let api = store.api {
                    if !results.documentsByTitle.isEmpty {
                        Section {
                            ForEach(results.documentsByTitle, id: \.id) { doc in
                                NavigationLink(
                                    destination: DocumentView(vm: tabManager.open(docId: doc.id, api: api),
                                                              onDisappear: store.load)
                                ) { WorkspaceRow(item: .note(doc)) }
                            }
                        } header: { SectionHeader(title: "Notes") }
                    }
                    if !results.documentsByContent.isEmpty {
                        ForEach(groupHits(results.documentsByContent),
                                id: \.doc.id) { group in
                            Section {
                                ForEach(group.hits, id: \.blockId) { hit in
                                    NavigationLink(
                                        destination: DocumentView(
                                            vm: tabManager.open(docId: hit.doc.id, api: api),
                                            onDisappear: store.load,
                                            scrollToBlockId: hit.blockId
                                        )
                                    ) {
                                        SnippetRow(hit: hit, query: query)
                                    }
                                }
                            } header: {
                                DocHitSectionHeader(doc: group.doc)
                            }
                        }
                    }
                    if !results.databases.isEmpty {
                        Section {
                            ForEach(results.databases, id: \.id) { db in
                                NavigationLink(
                                    destination: DatabaseView(dbId: db.id, api: api,
                                                              onDisappear: store.load)
                                ) { WorkspaceRow(item: .database(db)) }
                            }
                        } header: { SectionHeader(title: "Databases") }
                    }
                    if !results.folders.isEmpty {
                        Section {
                            ForEach(results.folders, id: \.id) { folder in
                                NavigationLink(
                                    destination: FolderView(store: store, folder: folder)
                                ) { FolderRow(folder: folder) }
                            }
                        } header: { SectionHeader(title: "Folders") }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search notes, content, databases, folders…")
            // iOS 26 : collapse the search field into the trailing nav icon
            // when the user starts scrolling, matching Photos / Mail. The
            // icon expands back when tapped or scrolled to the top.
            .searchToolbarBehavior(.minimize)
            .autocorrectionDisabled()
            // `.searchable` is backed by `UISearchTextField` which
            // ignores SwiftUI's `.tint` env. We push the colour
            // through the UIKit appearance proxy — applies to search
            // bars instantiated after this point, which covers the
            // re-mount that happens when the toggle flips.
            .onAppear { applySearchBarTint() }
            .onChange(of: settings.cursorFollowsAccent) { _, _ in
                applySearchBarTint()
            }
            .onChange(of: settings.accentChoice) { _, _ in
                applySearchBarTint()
            }
        }
    }

    @MainActor
    private func applySearchBarTint() {
        let color: UIColor = settings.cursorFollowsAccent
            ? UIColor(settings.accentColor)
            : .white
        UISearchTextField.appearance().tintColor = color
    }
}

// ── Search hit grouping ───────────────────────────────────────────────────────

/// One document plus every block-level hit that matched in it. Lets the
/// search UI show a single header per doc with multiple snippet previews
/// nested underneath instead of duplicating the doc row N times.
private struct DocHitGroup {
    let doc: DocumentMetaFfi
    let hits: [BlockSearchHitFfi]
}

/// Preserves first-seen order while grouping hits by `doc.id`. The Rust
/// backend returns hits document-by-document, depth-first within each
/// doc — keeping that order means the topmost match in the doc is the
/// first snippet shown.
private func groupHits(_ hits: [BlockSearchHitFfi]) -> [DocHitGroup] {
    var order: [String] = []
    var bucket: [String: [BlockSearchHitFfi]] = [:]
    var docs: [String: DocumentMetaFfi] = [:]
    for hit in hits {
        if bucket[hit.doc.id] == nil {
            order.append(hit.doc.id)
            docs[hit.doc.id] = hit.doc
        }
        bucket[hit.doc.id, default: []].append(hit)
    }
    return order.compactMap { id in
        guard let doc = docs[id], let arr = bucket[id] else { return nil }
        return DocHitGroup(doc: doc, hits: arr)
    }
}

// ── Doc-hit section header ────────────────────────────────────────────────────

/// Non-interactive header for the per-doc grouping of block hits.
/// Surfaces the doc icon and title above its snippet rows; doesn't
/// own a NavigationLink because the snippets themselves are the
/// navigation targets.
private struct DocHitSectionHeader: View {
    let doc: DocumentMetaFfi

    var body: some View {
        HStack(spacing: 10) {
            if let icon = doc.icon, !icon.isEmpty {
                Text(icon).font(.body)
            } else {
                Image(systemName: "doc.text")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Group {
                if doc.titlePlain.isEmpty { Text("Untitled") } else { Text(doc.titlePlain) }
            }
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

// ── Snippet row ───────────────────────────────────────────────────────────────

/// Single snippet row — owns exactly one NavigationLink (set by the
/// caller) so iOS's back-stack stays unambiguous. The matched tokens
/// in `hit.snippet` are bolded à la Notion.
private struct SnippetRow: View {
    let hit: BlockSearchHitFfi
    let query: String

    var body: some View {
        Text(highlightedSnippet)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }

    private var highlightedSnippet: AttributedString {
        var attr = AttributedString(hit.snippet)
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        for token in tokens {
            highlight(token, in: &attr)
        }
        return attr
    }

    private func highlight(_ token: String, in attr: inout AttributedString) {
        var cursor = attr.startIndex
        let needle = token.lowercased()
        while cursor < attr.endIndex,
              let range = attr[cursor...].range(of: needle,
                                                options: .caseInsensitive) {
            attr[range].font = .subheadline.bold()
            attr[range].foregroundColor = .primary
            cursor = range.upperBound
        }
    }
}
