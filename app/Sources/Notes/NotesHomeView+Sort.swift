import SwiftUI

// ── Sort + group derivation for the "All" list ────────────────────────────
//
// Extracted into its own file so the body of `NotesHomeView` doesn't
// trip the SwiftUI type checker — adding the toolbar Menu with three
// nested Pickers + the grouping branches inline pushed `body` past the
// "unable to type-check in reasonable time" wall on first attempt.

extension NotesHomeView {

    /// One contiguous Section of items the List can render. Title is the
    /// header (e.g. "Today", "B"); `id` is stable so SwiftUI diffs cells
    /// correctly across re-sorts.
    struct ItemGroup: Identifiable {
        let id: String
        let title: String?  // nil = no header (used for the .none grouping)
        let items: [WorkspaceItem]
    }

    // ── Sorting ───────────────────────────────────────────────────────────

    /// Returns `store.items` sorted by the active `sortKey`/`sortAscending`.
    var sortedItems: [WorkspaceItem] {
        let openedAt: [String: Int] = Dictionary(
            uniqueKeysWithValues: tabManager.recentlyViewed.enumerated()
                .map { ($1, $0) })
        let asc = sortAscending
        return store.items.sorted { a, b in
            // `naturalOrder` = "should a come before b under ascending".
            let naturalOrder: Bool
            switch sortKey {
            case .name:
                naturalOrder = a.titlePlain.localizedStandardCompare(b.titlePlain) == .orderedAscending
            case .createdAt:
                naturalOrder = a.createdAt < b.createdAt
            case .updatedAt:
                naturalOrder = a.updatedAt < b.updatedAt
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
            return buckets.keys.sorted().map { key in
                ItemGroup(id: key, title: key, items: buckets[key] ?? [])
            }
        case .createdAt, .updatedAt, .lastOpened:
            return Self.bucketByDate(items, key: groupBy,
                                     openedAt: Dictionary(
                                        uniqueKeysWithValues: tabManager.recentlyViewed
                                            .enumerated().map { ($1, $0) }))
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
            case .createdAt:  return parseDate(item.createdAt)
            case .updatedAt:  return parseDate(item.updatedAt)
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
        case .createdAt:  return item.createdAt
        case .updatedAt:  return item.updatedAt
        case .name, .lastOpened: return item.updatedAt
        }
    }

    // ── Row + Section rendering ───────────────────────────────────────────

    /// One Section of the grouped "All" list — extracted so the body of
    /// `NotesHomeView` doesn't push the SwiftUI type checker past the
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
                            case .note(let d):      store.delete(id: d.id)
                            case .database(let db): store.deleteDatabase(id: db.id)
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
    private func pickerOption(label: LocalizedStringKey,
                              systemImage: String,
                              isSelected: Bool) -> some View {
        Label {
            Text(label)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(isSelected ? settings.accentColor : .primary)
        }
    }

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
            // Pickers inside Menu render the Mail.app pattern : the
            // selected option keeps its original Label icon AND gets
            // a leading checkmark, both tinted by the section's tint.
            // The trade-off (vs explicit Buttons) is that Section
            // titles ("Sort by" etc.) are sometimes swallowed by
            // iOS — we keep them and accept the inconsistency.
            Section("Sort by") {
                Picker("Sort by", selection: $sortKeyRaw) {
                    ForEach(SortKey.allCases) { key in
                        pickerOption(label: key.label,
                                     systemImage: key.systemImage,
                                     isSelected: sortKey == key)
                            .tag(key.rawValue)
                    }
                }
                .pickerStyle(.inline)
            }
            Section("Order") {
                Picker("Order", selection: $sortAscending) {
                    pickerOption(label: "Ascending",
                                 systemImage: "arrow.up",
                                 isSelected: sortAscending)
                        .tag(true)
                    pickerOption(label: "Descending",
                                 systemImage: "arrow.down",
                                 isSelected: !sortAscending)
                        .tag(false)
                }
                .pickerStyle(.inline)
            }
            Section("Group by") {
                Picker("Group by", selection: $groupByRaw) {
                    ForEach(GroupBy.allCases) { key in
                        pickerOption(label: key.label,
                                     systemImage: key.systemImage,
                                     isSelected: groupBy == key)
                            .tag(key.rawValue)
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        // Neutral chrome — the sort icon shouldn't pick up the
        // TabView's accent color (per the .tint(.primary) convention
        // we follow for non-accent UI chrome).
        .tint(.primary)
        .accessibilityLabel("Sort and group")
    }
}

