import SwiftUI
import PinkhaFFI
import PinkhaCore
import PinkhaDesignSystem

// ── Sort + group derivation for the "All" list ────────────────────────────
//
// Extracted into its own file so the body of `LibraryView` doesn't
// trip the SwiftUI type checker — adding the toolbar Menu with three
// nested Pickers + the grouping branches inline pushed `body` past the
// "unable to type-check in reasonable time" wall on first attempt.

public extension LibraryView {

    /// One contiguous Section of items the List can render. Title is the
    /// header (e.g. "Today", "B"); `id` is stable so SwiftUI diffs cells
    /// correctly across re-sorts.
    struct ItemGroup: Identifiable {
        public let id: String
        let title: String?  // nil = no header (used for the .none grouping)
        let items: [WorkspaceItem]
    }

    // ── Sorting ───────────────────────────────────────────────────────────

    /// Returns `store.items` sorted by the active `sortKey`/`sortAscending`,
    /// filtered by the optional "hide books" toggle.
    var sortedItems: [WorkspaceItem] {
        let openedAt: [String: Int] = Dictionary(
            uniqueKeysWithValues: tabManager.recentlyViewed.enumerated()
                .map { ($1, $0) })
        let asc = sortAscending
        let base: [WorkspaceItem]
        if hideBooks {
            base = store.items.filter {
                if case .book = $0 { return false }
                return true
            }
        } else {
            base = store.items
        }
        return base.sorted { a, b in
            // `naturalOrder` = "should a come before b under ascending".
            let naturalOrder: Bool
            switch sortKey {
            case .name:
                naturalOrder = a.titlePlain.localizedStandardCompare(b.titlePlain) == .orderedAscending
            case .createdAt:
                naturalOrder = a.createdAt < b.createdAt
            case .updatedAt:
                naturalOrder = a.updatedAt < b.updatedAt
            case .publishedAt:
                naturalOrder = a.publishedAt < b.publishedAt
            case .lastOpened:
                // Lower MRU index = more recently opened. Ascending
                // means "oldest opened first" → higher index first.
                // Never-opened docs (.max) sink to the end.
                naturalOrder = (openedAt[a.id] ?? .max) > (openedAt[b.id] ?? .max)
            }
            return asc ? naturalOrder : !naturalOrder
        }
    }

    // ── Grouping ──────────────────────────────────────────────────────────

    /// `sortedItems` partitioned into `ItemGroup`s according to
    /// `groupBy`. With `.none` returns a single header-less group so
    /// the List rendering path is uniform.
    var groupedItems: [ItemGroup] {
        let items = sortedItems
        switch groupBy {
        case .none:
            return [ItemGroup(id: "all", title: nil, items: items)]
        case .name:
            let buckets = Dictionary(grouping: items) { item -> String in
                let first = item.titlePlain.trimmingCharacters(in: .whitespaces).first
                guard let c = first else { return "#" }
                return c.isLetter ? String(c).uppercased() : "#"
            }
            // Ascending = A → Z, descending = Z → A. The sort
            // direction the user picks for items also drives the
            // header order so the screen reads consistently.
            let keys = buckets.keys.sorted(by: sortAscending ? (<) : (>))
            return keys.map { key in
                ItemGroup(id: key, title: key, items: buckets[key] ?? [])
            }
        case .createdAt, .updatedAt, .publishedAt, .lastOpened:
            let groups = Self.bucketByDate(
                items,
                key: groupBy,
                openedAt: Dictionary(
                    uniqueKeysWithValues: tabManager.recentlyViewed
                        .enumerated().map { ($1, $0) }))
            // Ascending = chronological (Older → Today), descending
            // = recency-first (Today → Older). The natural bucket
            // order is recency-first, so we just reverse for
            // ascending.
            return sortAscending ? groups.reversed() : groups
        }
    }

    /// Buckets items into Today / Yesterday / This week / This month /
    /// Older, preserving the order they arrive in (= `sortedItems`).
    /// Empty buckets are dropped so headers don't show "0 items".
    private static func bucketByDate(_ items: [WorkspaceItem],
                                     key: GroupBy,
                                     openedAt: [String: Int]) -> [ItemGroup] {
        let now = Date()
        let cal = Calendar.current
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]

        func parseDate(_ string: String) -> Date? {
            iso.date(from: string) ?? isoFallback.date(from: string)
        }
        func dateFor(_ item: WorkspaceItem) -> Date? {
            switch key {
            case .createdAt:   return parseDate(item.createdAt)
            case .updatedAt:   return parseDate(item.updatedAt)
            case .publishedAt: return parseDate(item.publishedAt)
            case .lastOpened:
                // Map the MRU index back to a synthetic "recency rank";
                // we don't have wall-clock timestamps for opens, so all
                // recently-viewed items go into Today and the rest into
                // Older.
                if openedAt[item.id] != nil { return now }
                return Date.distantPast
            default: return nil
            }
        }

        var today: [WorkspaceItem] = []
        var yesterday: [WorkspaceItem] = []
        var thisWeek: [WorkspaceItem] = []
        var thisMonth: [WorkspaceItem] = []
        var older: [WorkspaceItem] = []

        for item in items {
            guard let date = dateFor(item) else { older.append(item); continue }
            if cal.isDateInToday(date) { today.append(item) }
            else if cal.isDateInYesterday(date) { yesterday.append(item) }
            else if let weekAgo = cal.date(byAdding: .day, value: -7, to: now),
                    date > weekAgo { thisWeek.append(item) }
            else if let monthAgo = cal.date(byAdding: .day, value: -30, to: now),
                    date > monthAgo { thisMonth.append(item) }
            else { older.append(item) }
        }

        let groups: [(String, [WorkspaceItem])] = [
            ("Today",      today),
            ("Yesterday",  yesterday),
            ("This week",  thisWeek),
            ("This month", thisMonth),
            ("Older",      older),
        ]
        return groups.compactMap { (title, items) in
            items.isEmpty ? nil : ItemGroup(id: title, title: title, items: items)
        }
    }

    /// ISO date string to show under each row's title — follows the
    /// active sort key so what the user sees matches what they sorted
    /// by. `lastOpened` and `name` have no natural per-row timestamp,
    /// so they fall back to `updatedAt` (= "last touched").
    func displayDate(for item: WorkspaceItem) -> String {
        switch sortKey {
        case .createdAt:   return item.createdAt
        case .updatedAt:   return item.updatedAt
        case .publishedAt: return item.publishedAt
        case .name, .lastOpened: return item.updatedAt
        }
    }

    // ── Row + Section rendering ───────────────────────────────────────────

    /// One Section of the grouped "All" list — extracted so the body of
    /// `LibraryView` doesn't push the SwiftUI type checker past the
    /// "unable to type-check in reasonable time" wall.
    @ViewBuilder
    func groupSection(_ group: ItemGroup, api: PinkhaApi) -> some View {
        Section {
            ForEach(group.items) { item in
                itemRow(item, api: api)
                    // Explicit swipeActions (not `.onDelete`) so the
                    // trash icon + label match every other swipe delete
                    // in the app.
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            switch item {
                            case .leaf(let d):      store.delete(id: d.id)
                            // Stage the dialog — the user picks whether
                            // the pages inside follow the book.
                            case .book(let db): pendingBookDeletion = db
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
            }
        } header: {
            // No grouping → single "All" header. Grouped → the bucket
            // title (Today / "B" / This week / etc.).
            SectionHeader(title: group.title.map { LocalizedStringKey($0) } ?? "All")
        }
    }

    /// One Picker option rendered as Mail.app does : when selected,
    /// the Picker's own checkmark appears to the left (system white)
    /// and the original icon (calendar, arrow, etc.) is tinted in the
    /// app's accent colour. Unselected rows keep their icon in
    /// `.primary` so the eye spots the active row at a glance.
    @ViewBuilder
    func pickerOption(label: LocalizedStringKey,
                      systemImage: String,
                      isSelected: Bool) -> some View {
        // iOS strips `.foregroundStyle` from SF Symbol images
        // rendered inside a Menu's `Button` label. The workaround :
        // pre-bake the colour into a `UIImage` via `.withTintColor`
        // + `.alwaysOriginal` rendering mode, then hand the
        // pre-coloured image to `Label`. UIKit can't override what
        // it didn't generate itself.
        Label {
            Text(label)
        } icon: {
            if isSelected {
                Image(uiImage: tintedSymbol("checkmark", color: UIColor(settings.accentColor)))
            } else {
                Image(systemName: systemImage)
            }
        }
    }

    /// Returns a `UIImage` rendition of `name` painted in `color`.
    /// Uses `.alwaysOriginal` so UIKit doesn't re-tint it through
    /// the host view's tint when the image is mounted in a label.
    func tintedSymbol(_ name: String, color: UIColor) -> UIImage {
        Self.tintedSymbolStatic(name, color: color)
    }
    /// File-scope copy of `tintedSymbol` exposed so non-`LibraryView`
    /// callers (`ShelvesSectionView`, `ShelfSortRow`) can pre-bake
    /// their own checkmark icons with the same recipe.
    static func tintedSymbolStatic(_ name: String, color: UIColor) -> UIImage {
        let cfg = UIImage.SymbolConfiguration(textStyle: .body)
        let base = UIImage(systemName: name, withConfiguration: cfg) ?? UIImage()
        return base.withTintColor(color, renderingMode: .alwaysOriginal)
    }
}

/// Top-level shim so callers outside `LibraryView` can use the same
/// pre-tinted SF Symbol recipe without instantiating a view.
func tintedSymbol(_ name: String, color: UIColor) -> UIImage {
    LibraryView.tintedSymbolStatic(name, color: color)
}

extension LibraryView {

    // ── Toolbar Menu ──────────────────────────────────────────────────────

    /// Trailing-toolbar menu : Sort by / Order / Group by. Each section
    /// uses explicit `Button`s instead of `Picker(.inline)` because in
    /// iOS 26, an inline Picker inside a `Menu` swallows the parent
    /// `Section`'s title — the user sees rows + dividers but no
    /// section headers. Manual checkmark = `Label(checked)` swap on
    /// the active item.
    @ViewBuilder
    var sortMenuButton: some View {
        Menu {
            // iOS 26 swallows the `Section(_)` header when the body
            // contains an inline `Picker` — the rows render but the
            // title vanishes. We keep the Mail.app vocabulary by
            // emitting explicit `Button` rows ourselves and toggling
            // a leading checkmark on the active option. The
            // `Section("…")` wrapper still groups the rows visually
            // and the title survives because the body is plain
            // Buttons (no Picker).
            Section("Sort by") {
                ForEach(SortKey.allCases) { key in
                    Button { sortKeyRaw = key.rawValue } label: {
                        pickerOption(
                            label: key.label,
                            systemImage: key.systemImage,
                            isSelected: sortKey == key)
                    }
                }
            }
            Section("Order") {
                Button { sortAscending = true } label: {
                    pickerOption(
                        label: "Ascending",
                        systemImage: "arrow.up",
                        isSelected: sortAscending)
                }
                Button { sortAscending = false } label: {
                    pickerOption(
                        label: "Descending",
                        systemImage: "arrow.down",
                        isSelected: !sortAscending)
                }
            }
            Section("Group by") {
                ForEach(GroupBy.allCases) { key in
                    Button { groupByRaw = key.rawValue } label: {
                        pickerOption(
                            label: key.label,
                            systemImage: key.systemImage,
                            isSelected: groupBy == key)
                    }
                }
            }
            Section("Show") {
                // `Toggle` inside a Menu renders as a tappable row with a
                // checkmark — same vocabulary as the SortKey / GroupBy
                // pickers above. The books tab is unaffected.
                Toggle(isOn: Binding(
                    get: { !hideBooks },
                    set: { hideBooks = !$0 }
                )) {
                    Label("Books", systemImage: "tablecells")
                }
            }
        } label: {
            // Filled glyph signals "grouping is active" — a passive
            // hint that the list isn't a flat sort. Falls back to the
            // outline when groupBy is `.none`.
            Image(systemName: groupBy == .none
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        // Neutral chrome — the sort icon shouldn't pick up the
        // TabView's accent color (per the .tint(.primary) convention
        // we follow for non-accent UI chrome).
        .tint(.primary)
        .accessibilityLabel("Sort and group")
    }
}

