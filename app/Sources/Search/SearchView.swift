import SwiftUI
import PinkhaFFI
import PinkhaCore
import PinkhaDesignSystem

// ── Search tab ────────────────────────────────────────────────────────────────

/// Search tab — full-library super search. Hits four axes in parallel
/// (note titles, note content, book titles, shelf names) and groups
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
                    if !results.leavesByTitle.isEmpty {
                        Section {
                            ForEach(results.leavesByTitle, id: \.id) { doc in
                                NavigationLink(
                                    destination: LeafView(vm: tabManager.open(leafId: doc.id, api: api),
                                                              onDisappear: store.load)
                                ) { LibraryRow(item: .note(doc)) }
                            }
                        } header: { SectionHeader(title: "Notes") }
                    }
                    if !results.leavesByContent.isEmpty {
                        ForEach(groupHits(results.leavesByContent),
                                id: \.doc.id) { group in
                            Section {
                                ForEach(group.hits, id: \.blockId) { hit in
                                    NavigationLink(
                                        destination: LeafView(
                                            vm: tabManager.open(leafId: hit.doc.id, api: api),
                                            onDisappear: store.load,
                                            scrollToBlockId: hit.blockId
                                        )
                                    ) {
                                        SnippetRow(hit: hit, query: query)
                                    }
                                }
                            } header: {
                                LeafHitSectionHeader(doc: group.doc)
                            }
                        }
                    }
                    if !results.books.isEmpty {
                        Section {
                            ForEach(results.books, id: \.id) { db in
                                NavigationLink(
                                    destination: BookView(bookId: db.id, api: api,
                                                              onDisappear: store.load)
                                ) { LibraryRow(item: .book(db)) }
                            }
                        } header: { SectionHeader(title: "Books") }
                    }
                    if !results.shelves.isEmpty {
                        Section {
                            ForEach(results.shelves, id: \.id) { shelf in
                                NavigationLink(
                                    destination: ShelfView(store: store, shelf: shelf)
                                ) { ShelfRow(shelf: shelf) }
                            }
                        } header: { SectionHeader(title: "Shelves") }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search notes, content, books, shelves…")
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

/// One leaf plus every block-level hit that matched in it. Lets the
/// search UI show a single header per doc with multiple snippet previews
/// nested underneath instead of duplicating the doc row N times.
private struct LeafHitGroup {
    let doc: LeafMetaFfi
    let hits: [BlockSearchHitFfi]
}

/// Preserves first-seen order while grouping hits by `doc.id`. The Rust
/// backend returns hits leaf-by-leaf, depth-first within each
/// doc — keeping that order means the topmost match in the doc is the
/// first snippet shown.
private func groupHits(_ hits: [BlockSearchHitFfi]) -> [LeafHitGroup] {
    var order: [String] = []
    var bucket: [String: [BlockSearchHitFfi]] = [:]
    var docs: [String: LeafMetaFfi] = [:]
    for hit in hits {
        if bucket[hit.doc.id] == nil {
            order.append(hit.doc.id)
            docs[hit.doc.id] = hit.doc
        }
        bucket[hit.doc.id, default: []].append(hit)
    }
    return order.compactMap { id in
        guard let doc = docs[id], let arr = bucket[id] else { return nil }
        return LeafHitGroup(doc: doc, hits: arr)
    }
}

// ── Doc-hit section header ────────────────────────────────────────────────────

/// Non-interactive header for the per-doc grouping of block hits.
/// Surfaces the doc icon and title above its snippet rows; doesn't
/// own a NavigationLink because the snippets themselves are the
/// navigation targets.
private struct LeafHitSectionHeader: View {
    let doc: LeafMetaFfi

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
