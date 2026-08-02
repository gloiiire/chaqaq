import SwiftUI
import PinkhaFFI
import PinkhaCore
import LeafFeature


// ── Book view model ───────────────────────────────────────────────────────
//
// State holder for the whole BookView screen :
//   • Doc-like header (cover / icon / title / description).
//   • View switcher (List / Table / Board / Calendar / Gallery).
//   • Per-view group-by, search query, in-memory filters.
//   • Pass-through to the FFI for every mutation.

/// In-memory filter clause. Property + freeform query string ; the VM
/// translates it into a `Contains` condition when running the search
/// path. Persisted filters land in a follow-up PR — for now the user's
/// filter list is session-scoped.
public struct BookFilter: Identifiable, Equatable {
    public let id: UUID
    var propertyId: String
    var queryDraft: String
}

@MainActor
@Observable
public final class BookViewModel {
    let bookId: String
    @ObservationIgnored let api: PinkhaApi

    // ── Header ────────────────────────────────────────────────────────────────

    var titlePlain: String = ""
    var descriptionPlain: String = ""
    var cover: String?
    var icon: String?
    /// Read-only flag — propagated from the persisted `Book.locked`.
    /// When `true`, the toolbar's add button is dimmed and every
    /// view component hides its mutation affordances.
    var locked: Bool = false

    // ── Schema + data ─────────────────────────────────────────────────────────

    var properties: [PropertyFfi] = []
    var entries: [EntryFfi] = []
    var views: [ViewFfi] = []
    var errorMessage: String?

    /// UUID of the view currently driving the body. Defaults to the
    /// first view in `views` after load.
    var activeViewId: String?

    /// Currently active sort. `nil` means insertion order.
    private(set) var activeSort: ActiveSort? = nil

    /// UUID of the Date property driving every row's publish date —
    /// mirrors `Book.published_at_source`. `nil` = publish dates
    /// follow `created_at` unless overridden per row.
    private(set) var publishedAtSource: String? = nil

    /// Which entry-level date the active sort is keyed by, if any.
    /// `.none` when no date sort is active (either column sort or
    /// no sort at all). Drives the checkmark in the toolbar's date
    /// sort menu.
    private(set) var activeDateSort: DateSortKind? = nil

    /// Direction of the active date sort. `nil` whenever
    /// `activeDateSort` is `nil`. Kept separate (not folded into the
    /// enum) so the toolbar can match kind and direction independently.
    private(set) var activeDateSortAscending: Bool? = nil

    /// `true` when the active sort is exactly this date sort — kind AND
    /// direction. Drives the per-row checkmark in the toolbar's date
    /// sort menu, where "Published newest" and "Published oldest" are
    /// distinct rows.
    func isDateSort(_ kind: DateSortKind, ascending: Bool) -> Bool {
        activeDateSort == kind && activeDateSortAscending == ascending
    }

    /// Date-only sort vocabulary surfaced in the toolbar menu.
    enum DateSortKind: String, Equatable {
        case created
        case published
    }

    /// In-memory filter clauses applied client-side to `entries`.
    var filters: [BookFilter] = []
    /// Inline search box content. Empty means "no search applied".
    var searchQuery: String = ""
    /// Property used to bucket entries in List / Board / Gallery views.
    /// `nil` means "no grouping" — one synthetic bucket holds all entries.
    var groupByPropertyId: String?
    /// Which group titles the user has collapsed. Session-scoped.
    private(set) var collapsedGroups: Set<String> = []

    /// Date-based grouping config for the active view. `nil` = flat
    /// rendering. Mirrors `View.date_grouping` on the Rust side and
    /// is persisted on every change via [`setDateGrouping`]. Loaded
    /// from the active view's `dateGrouping` field on view switch.
    private(set) var dateGrouping: DateGroupingFfi?

    /// Per-node collapse state for the date-group tree. Keyed by
    /// `DateGroupNodeFfi.id` (e.g. `"2024/-/-"`, `"2024/3/-"`).
    /// Session-scoped — survives view switches but not relaunch, by
    /// design (these collapse choices are ephemeral UI state).
    private(set) var collapsedDateGroups: Set<String> = []

    struct ActiveSort: Equatable {
        let propertyId: String
        let ascending: Bool
    }

    // ── Hidden plumbing ───────────────────────────────────────────────────────

    /// ID of the hidden system property storing each entry's linked leaf ID.
    @ObservationIgnored private(set) var pagePropertyId: String? = nil

    @ObservationIgnored private let pagePropName = "__pinkha_page__"
    @ObservationIgnored private let namePropName = "Name"

    // Cache of doc icons per entry id — lazily filled on demand to keep
    // the list scroll fast.
    @ObservationIgnored private var iconCache: [String: String?] = [:]

    init(bookId: String, api: PinkhaApi) {
        self.bookId = bookId
        self.api = api
    }

    // ── Loading ──────────────────────────────────────────────────────────────

    func load() {
        guard let db = fetchDB() else { return }
        var needsReload = false

        if let pp = db.properties.first(where: { $0.name == pagePropName }) {
            pagePropertyId = pp.id
        } else {
            let id = UUID().uuidString.lowercased()
            createSystemProp(PropertyFfi(id: id, name: pagePropName, propertyType: .text))
            pagePropertyId = id
            needsReload = true
        }

        let visible = db.properties.filter { $0.name != pagePropName }
        let hasTitle = visible.contains { if case .title = $0.propertyType { return true }; return false }
        if !hasTitle {
            let id = UUID().uuidString.lowercased()
            createSystemProp(PropertyFfi(id: id, name: namePropName, propertyType: .title))
            needsReload = true
        }

        applyDB(needsReload ? (fetchDB() ?? db) : db)
    }

    private func applyDB(_ db: BookFfi) {
        titlePlain       = db.title.map(\.content).joined()
        descriptionPlain = db.description.map(\.content).joined()
        cover            = db.cover
        icon             = db.icon
        locked           = db.locked
        publishedAtSource = db.publishedAtSource
        pagePropertyId   = db.properties.first(where: { $0.name == pagePropName })?.id

        var allViews = db.views ?? []

        // Mobile-first default — every book always has a List view
        // available so users on iPhone never get stuck on the Table
        // layout. Side-effect : creates a Notion-style "List" entry on
        // existing books imported as Table-only.
        if !allViews.contains(where: { if case .list = $0.type { return true }; return false }) {
            let listId = UUID().uuidString.lowercased()
            let json = newViewJson(id: listId, name: "List", type: .list)
            if tryCatch(into: &errorMessage, {
                try api.addView(bookId: bookId, viewJson: json)
            }) != nil {
                let listView = ViewFfi(id: listId, name: "List", type: .list)
                allViews.insert(listView, at: 0)
            }
        }

        views = allViews
        // Active view defaults to the List entry — that's the visual
        // default the user expects on mobile, regardless of the order
        // the DB shipped its views in.
        if activeViewId == nil || !allViews.contains(where: { $0.id == activeViewId }) {
            let listFirst = allViews.first(where: {
                if case .list = $0.type { return true }; return false
            })
            activeViewId = listFirst?.id ?? allViews.first?.id
        }
        // Hydrate the date-grouping cache from the now-active view so
        // a freshly opened book picks up the persisted config without
        // a separate activateView call.
        dateGrouping = allViews.first(where: { $0.id == activeViewId })?.dateGrouping

        if let view = allViews.first, let s = view.sorts.first {
            let asc = s.order == "Ascending"
            switch s.source {
            case "Property":
                activeSort = ActiveSort(propertyId: s.propertyId, ascending: asc)
                activeDateSort = nil
                activeDateSortAscending = nil
            case "Created":
                activeDateSort = .created
                activeDateSortAscending = asc
                activeSort = nil
            case "Published":
                activeDateSort = .published
                activeDateSortAscending = asc
                activeSort = nil
            default:
                activeSort = nil
                activeDateSort = nil
                activeDateSortAscending = nil
            }
        } else {
            activeSort = nil
            activeDateSort = nil
            activeDateSortAscending = nil
        }

        var visible = db.properties.filter { $0.name != pagePropName }
        visible.sort {
            if case .title = $0.propertyType { return true }
            if case .title = $1.propertyType { return false }
            return false
        }
        properties = visible
        entries    = db.entries
        refreshSortedEntries()
    }

    // ── Active view + view picker ────────────────────────────────────────────

    var activeView: ViewFfi? { views.first { $0.id == activeViewId } }

    func activateView(id: String) {
        guard views.contains(where: { $0.id == id }) else { return }
        activeViewId = id
        // Switching views also resets transient UI state.
        searchQuery = ""
        collapsedGroups = []
        collapsedDateGroups = []
        // Pick up the new view's persisted date-grouping config (if any).
        dateGrouping = views.first(where: { $0.id == id })?.dateGrouping
    }

    func addView(type: ViewTypeFfi) {
        let id = UUID().uuidString.lowercased()
        let name: String
        switch type {
        case .list:     name = "List"
        case .table:    name = "Table"
        case .kanban:   name = "Board"
        case .calendar: name = "Calendar"
        case .gallery:  name = "Gallery"
        }
        // Hand-rolled JSON because the Rust `View` struct requires
        // `filters` and `sorts` keys ; ViewFfi-side encoding skips
        // `filters` (the VM manages filters separately).
        let json = newViewJson(id: id, name: name, type: type)
        guard tryCatch(into: &errorMessage, {
            try api.addView(bookId: bookId, viewJson: json)
        }) != nil else { return }
        let view = ViewFfi(id: id, name: name, type: type)
        views.append(view)
        activeViewId = id
    }

    /// Builds the exact JSON shape Rust's `View` deserializer expects :
    /// `{ id, name, type_, filters: [], sorts: [] }`. The `type_` payload
    /// is externally-tagged like serde, matching `ViewTypeFfi.encode`.
    private func newViewJson(id: String, name: String, type: ViewTypeFfi) -> String {
        let typeJson: String
        switch type {
        case .list:    typeJson = "\"List\""
        case .table:   typeJson = "\"Table\""
        case .gallery: typeJson = "\"Gallery\""
        case .kanban(let g):
            typeJson = "{\"Kanban\":{\"group_by\":\"\(g)\"}}"
        case .calendar(let p):
            typeJson = "{\"Calendar\":{\"property_id\":\"\(p)\"}}"
        }
        return "{\"id\":\"\(id)\",\"name\":\"\(name)\",\"type_\":\(typeJson),\"filters\":[],\"sorts\":[]}"
    }

    // ── Header mutations ─────────────────────────────────────────────────────

    func saveTitle(_ plain: String) {
        // Locking mid-edit must not let the pending draft commit on blur —
        // Rust rejects it anyway; bailing here avoids a useless error alert.
        guard !locked else { return }
        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only mirror locally once the write actually landed. `tryCatch`
        // swallows the error into `errorMessage`, so an unconditional
        // assignment left the UI showing a value the database rejected —
        // the user saw an error alert *and* their edit apparently applied.
        let result: ()? = tryCatch(into: &errorMessage) {
            try api.updateBookTitle(id: bookId, newTitle: trimmed)
        }
        guard result != nil else { return }
        titlePlain = trimmed
    }

    func saveDescription(_ plain: String) {
        guard !locked else { return }
        let result: ()? = tryCatch(into: &errorMessage) {
            try api.updateBookDescription(id: bookId, description: plain)
        }
        guard result != nil else { return }
        descriptionPlain = plain
    }

    func saveCover(_ identifier: String?) {
        let result: ()? = tryCatch(into: &errorMessage) {
            try api.updateBookCover(id: bookId, cover: identifier)
        }
        guard result != nil else { return }
        cover = identifier
    }

    /// Persists raw image data to the shared covers directory then
    /// updates the DB to reference the resulting file. Mirrors the
    /// leaf flow so docs and DBs share their cover store.
    func saveCoverFromData(_ data: Data) {
        guard let directory = try? LeafViewModel.coversDirectory() else { return }
        let filename = "\(UUID().uuidString.lowercased()).jpg"
        let url = directory.appendingPathComponent(filename)
        try? data.write(to: url, options: .atomic)
        saveCover(filename)
    }

    func saveCoverFromFile(_ url: URL) {
        guard let directory = try? LeafViewModel.coversDirectory(),
              let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let filename = "\(UUID().uuidString.lowercased()).\(ext)"
        let dest = directory.appendingPathComponent(filename)
        try? data.write(to: dest, options: .atomic)
        saveCover(filename)
    }

    func saveIcon(_ identifier: String?) {
        let result: ()? = tryCatch(into: &errorMessage) {
            try api.updateBookIcon(id: bookId, icon: identifier)
        }
        guard result != nil else { return }
        icon = identifier
    }

    /// Toggles the read-only flag.
    ///
    /// The local flag follows the write rather than leading it: a failed
    /// toggle used to flip the padlock anyway, so the user ended up editing
    /// a book the backend still considered locked and every subsequent
    /// write was rejected.
    func toggleLock() {
        let next = !locked
        let result: ()? = tryCatch(into: &errorMessage) {
            try api.updateBookLocked(id: bookId, locked: next)
        }
        guard result != nil else { return }
        locked = next
    }

    // ── Entry mutations ──────────────────────────────────────────────────────

    func addEntry() {
        guard let leafId  = tryCatch(into: &errorMessage, { try api.createLeaf(title: "") }),
              let pageId = pagePropertyId
        else { return }
        var initial: [String: PropertyValueFfi] = [pageId: .text(leafId)]
        if let nameId = namePropertyId { initial[nameId] = .title([]) }
        // Pre-seed group-by property so a row created from a group's
        // quick-add lands in the right bucket.
        guard let vJson = encode(initial),
              let entryId = tryCatch(into: &errorMessage, {
                  try api.addEntry(bookId: bookId, valuesJson: vJson)
              })
        else { return }
        entries.append(EntryFfi(id: entryId, createdAt: "", values: initial, leafId: leafId))
    }

    /// Same as `addEntry()` but pre-fills the group-by property with
    /// `groupTitle` so the new row materialises inside the right bucket.
    func addEntry(forGroup groupTitle: String) {
        guard let groupProp = groupByPropertyId else { addEntry(); return }
        guard let leafId  = tryCatch(into: &errorMessage, { try api.createLeaf(title: "") }),
              let pageId = pagePropertyId
        else { return }
        var initial: [String: PropertyValueFfi] = [pageId: .text(leafId)]
        if let nameId = namePropertyId { initial[nameId] = .title([]) }
        initial[groupProp] = valueMatching(group: groupTitle)
        guard let vJson = encode(initial),
              let entryId = tryCatch(into: &errorMessage, {
                  try api.addEntry(bookId: bookId, valuesJson: vJson)
              })
        else { return }
        entries.append(EntryFfi(id: entryId, createdAt: "", values: initial, leafId: leafId))
    }

    /// Quick-add preset hook. Currently maps every preset to a plain
    /// row ; a future PR will read templates from the DB.
    func addEntry(preset: String) { addEntry() }

    private func valueMatching(group: String) -> PropertyValueFfi {
        guard let prop = properties.first(where: { $0.id == groupByPropertyId }) else {
            return .text(group)
        }
        switch prop.propertyType {
        case .selection:           return .selection(group)
        case .selectionMultiple:   return .selectionMultiple([group])
        case .checkbox:            return .checkbox(group == "Checked")
        default:                   return .text(group)
        }
    }

    func deleteEntry(id: String) {
        if let leafId = leafId(forEntryId: id) {
            tryCatch(into: &errorMessage) { try api.deleteLeaf(id: leafId) }
        }
        tryCatch(into: &errorMessage) { try api.deleteEntry(bookId: bookId, entryId: id) }
        entries.removeAll { $0.id == id }
    }

    func updateCell(entryId: String, propertyId: String, value: PropertyValueFfi) {
        guard let idx = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[idx].values[propertyId] = value
        persist(entryIndex: idx)
    }

    // ── Properties ───────────────────────────────────────────────────────────

    func addProperty(name: String, type: PropertyTypeFfi) {
        let prop = PropertyFfi(id: UUID().uuidString.lowercased(), name: name, propertyType: type)
        createSystemProp(prop)
        properties.append(prop)
    }

    func renameProperty(id: String, newName: String) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        tryCatch(into: &errorMessage) {
            try api.renameProperty(bookId: bookId, propertyId: id, newName: name)
        }
        if let i = properties.firstIndex(where: { $0.id == id }) {
            properties[i] = PropertyFfi(id: id, name: name, propertyType: properties[i].propertyType)
        }
    }

    func deleteProperty(id: String) {
        guard let prop = properties.first(where: { $0.id == id }),
              !(prop.propertyType == .title)
        else { return }
        tryCatch(into: &errorMessage) {
            try api.deleteProperty(bookId: bookId, propertyId: id)
        }
        properties.removeAll { $0.id == id }
        for i in entries.indices { entries[i].values.removeValue(forKey: id) }
        if groupByPropertyId == id { groupByPropertyId = nil }
    }

    // ── Grouping ─────────────────────────────────────────────────────────────

    func setGroupBy(propertyId: String?) {
        groupByPropertyId = propertyId
        collapsedGroups = []
    }

    func toggleGroup(_ title: String) {
        if collapsedGroups.contains(title) {
            collapsedGroups.remove(title)
        } else {
            collapsedGroups.insert(title)
        }
    }

    func isGroupCollapsed(_ title: String) -> Bool { collapsedGroups.contains(title) }

    // ── Date grouping ────────────────────────────────────────────────────────

    /// Replaces (or clears, when `nil`) the active view's date-grouping
    /// config and persists it via the FFI so it survives a relaunch.
    /// Resets the collapse set to mirror `setGroupBy` semantics.
    func setDateGrouping(_ grouping: DateGroupingFfi?) {
        guard let viewId = activeViewId else { return }
        dateGrouping = grouping
        collapsedDateGroups = []
        tryCatch(into: &errorMessage) {
            try api.setViewDateGrouping(
                bookId: bookId,
                viewId: viewId,
                grouping: grouping
            )
        }
        // Mirror the change on the cached ViewFfi so a subsequent
        // switch-out-and-back-in surfaces the new config without
        // hitting Rust again.
        if let idx = views.firstIndex(where: { $0.id == viewId }) {
            let old = views[idx]
            views[idx] = ViewFfi(
                id: old.id,
                name: old.name,
                type: old.type,
                sorts: old.sorts,
                dateGrouping: grouping
            )
        }
    }

    func toggleDateGroup(_ id: String) {
        if collapsedDateGroups.contains(id) {
            collapsedDateGroups.remove(id)
        } else {
            collapsedDateGroups.insert(id)
        }
    }

    func isDateGroupCollapsed(_ id: String) -> Bool {
        collapsedDateGroups.contains(id)
    }

    /// In-memory date-grouping pass over the filtered+searched entries.
    /// Mirrors the Rust `build_date_groups` algorithm so the tree
    /// renders the same regardless of whether the source is the local
    /// filter pipeline or the persisted Rust query. `[]` means no
    /// grouping is active — callers fall back to `groupedRows`.
    var dateGroupedTree: [DateGroupNodeFfi] {
        guard let g = dateGrouping else { return [] }
        return Self.buildDateGroups(filteredEntries, properties: properties, config: g)
    }

    /// Pure helper — kept static so it's trivially unit-testable from
    /// outside the VM with a custom entry list.
    ///
    /// Strategy : pre-sort entries chronologically (in the user's
    /// `ascending` direction), then walk the sorted list to build the
    /// tree incrementally. We deliberately avoid any dictionary
    /// iteration during the tree build because Swift's `Dictionary`
    /// iteration order is hash-based — feeding it bucketed entries
    /// shuffles their visual order between visits whenever the
    /// underlying `entries` array changes (e.g. after opening a row
    /// and coming back). Walking the pre-sorted list and appending
    /// into the right node guarantees the same input ALWAYS yields
    /// the same tree.
    static func buildDateGroups(_ entries: [EntryFfi],
                                properties: [PropertyFfi],
                                config g: DateGroupingFfi) -> [DateGroupNodeFfi] {
        // Resolve ymd once per entry so the sort comparator and the
        // build loop share the same lookup.
        let withYmd: [(EntryFfi, (Int, Int, Int)?)] = entries.map {
            ($0, entryYmd(entry: $0, source: g.source, properties: properties))
        }

        // Pre-sort. "No date" entries sink to the bottom regardless
        // of direction so the missing-date bucket consistently lives
        // at the end of the rendered list.
        let sorted = withYmd.sorted { a, b in
            switch (a.1, b.1) {
            case (nil, nil): return false
            case (nil, _):   return false  // a sinks → b first
            case (_, nil):   return true   // b sinks → a first
            case let (lhs?, rhs?):
                if lhs == rhs { return false }
                return g.ascending ? (lhs < rhs) : (lhs > rhs)
            }
        }

        switch g.granularity {
        case .year:      return buildFlat(sorted, key: .year)
        case .month:     return buildFlat(sorted, key: .month)
        case .day:       return buildFlat(sorted, key: .day)
        case .yearMonth: return buildYearMonth(sorted)
        }
    }

    // ── Date grouping helpers ────────────────────────────────────────────

    private static func entryYmd(entry: EntryFfi,
                                 source: DateGroupingSourceFfi,
                                 properties: [PropertyFfi]) -> (Int, Int, Int)? {
        let raw: String
        switch source {
        case .created:
            raw = entry.createdAt
        case .published:
            raw = entry.publishedAt.isEmpty ? entry.createdAt : entry.publishedAt
        case .property(let propId):
            // Validate the property still exists ; fall back to "no
            // date" rather than created_at so a deleted column doesn't
            // silently lump every entry into today.
            guard properties.contains(where: { $0.id == propId }) else { return nil }
            guard case .date(let s) = entry.values[propId], !s.isEmpty else { return nil }
            raw = s
        }
        return parseYmd(raw)
    }

    /// String-slicing parser matching the Rust `parse_ymd` and the
    /// Swift `parsePinkhaDate` shapes. Avoids the locale + timezone
    /// gymnastics of `ISO8601DateFormatter` by only reading the first
    /// 10 chars `YYYY-MM-DD`, which both RFC 3339 and bare dates share.
    private static func parseYmd(_ s: String) -> (Int, Int, Int)? {
        guard s.count >= 10 else { return nil }
        let head = String(s.prefix(10))
        let parts = head.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]),
              let m = Int(parts[1]),
              let d = Int(parts[2]),
              (1...12).contains(m),
              (1...31).contains(d)
        else { return nil }
        return (y, m, d)
    }

    private enum FlatKeyKind { case year, month, day }

    /// Single-pass build for the flat granularities (Year / Month /
    /// Day). Each unique `ymd`-derived key gets one node ; entries
    /// land in their existing node so we never re-iterate a dict.
    private static func buildFlat(_ sorted: [(EntryFfi, (Int, Int, Int)?)],
                                  key kind: FlatKeyKind) -> [DateGroupNodeFfi] {
        var nodes: [DateGroupNodeFfi] = []
        // Index lookup keeps the loop O(n) ; the array is the source
        // of truth for both order and content.
        var indexByKey: [String: Int] = [:]
        for (entry, ymd) in sorted {
            let (year, month, day) = decompose(ymd, kind: kind)
            let key = flatKey(year, month, day)
            if let i = indexByKey[key] {
                nodes[i].entries.append(entry)
            } else {
                nodes.append(DateGroupNodeFfi(
                    labelYear: year,
                    labelMonth: month,
                    labelDay: day,
                    entries: [entry],
                    children: []
                ))
                indexByKey[key] = nodes.count - 1
            }
        }
        return nodes
    }

    /// Two-level build for the hierarchical `yearMonth` granularity.
    /// Same trick as `buildFlat` ; we walk the sorted list once,
    /// finding-or-creating the year node, then the month child.
    private static func buildYearMonth(_ sorted: [(EntryFfi, (Int, Int, Int)?)]) -> [DateGroupNodeFfi] {
        var years: [DateGroupNodeFfi] = []
        var yearIndex: [String: Int] = [:]
        for (entry, ymd) in sorted {
            let year = ymd.map { $0.0 }
            let month = ymd.map { $0.1 }
            let yKey = year.map(String.init) ?? "ND"
            let yi: Int
            if let existing = yearIndex[yKey] {
                yi = existing
            } else {
                years.append(DateGroupNodeFfi(
                    labelYear: year,
                    labelMonth: nil,
                    labelDay: nil,
                    entries: [],
                    children: []
                ))
                yi = years.count - 1
                yearIndex[yKey] = yi
            }
            if let mi = years[yi].children.firstIndex(where: { $0.labelMonth == month }) {
                years[yi].children[mi].entries.append(entry)
            } else {
                years[yi].children.append(DateGroupNodeFfi(
                    labelYear: year,
                    labelMonth: month,
                    labelDay: nil,
                    entries: [entry],
                    children: []
                ))
            }
        }
        return years
    }

    private static func decompose(_ ymd: (Int, Int, Int)?,
                                  kind: FlatKeyKind) -> (Int?, Int?, Int?) {
        switch kind {
        case .year:  return (ymd.map { $0.0 }, nil, nil)
        case .month: return (ymd.map { $0.0 }, ymd.map { $0.1 }, nil)
        case .day:   return (ymd.map { $0.0 }, ymd.map { $0.1 }, ymd.map { $0.2 })
        }
    }

    private static func flatKey(_ y: Int?, _ m: Int?, _ d: Int?) -> String {
        "\(y.map(String.init) ?? "ND")/\(m.map(String.init) ?? "-")/\(d.map(String.init) ?? "-")"
    }

    /// `[(groupTitle, entriesInGroup)]` for the active view. With no
    /// group-by selected, returns one bucket titled "All" with every
    /// (filtered + searched) entry.
    var groupedRows: [(title: String, entries: [EntryFfi])] {
        let base = filteredEntries
        guard let groupId = groupByPropertyId,
              let prop = properties.first(where: { $0.id == groupId })
        else {
            return [(title: "", entries: base)]
        }
        var buckets: [String: [EntryFfi]] = [:]
        var order: [String] = []
        for entry in base {
            let key = bucketKey(for: entry.values[groupId] ?? .empty, prop: prop)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private func bucketKey(for value: PropertyValueFfi, prop: PropertyFfi) -> String {
        switch prop.propertyType {
        case .checkbox:
            if case .checkbox(let b) = value { return b ? "Checked" : "Unchecked" }
            return "Unchecked"
        case .selectionMultiple:
            if case .selectionMultiple(let vs) = value, let first = vs.first { return first }
            return "No tag"
        case .selection:
            if case .selection(let s) = value, let s, !s.isEmpty { return s }
            return "No tag"
        default:
            return value.displayText.isEmpty ? "Untitled" : value.displayText
        }
    }

    // ── Filters + search ─────────────────────────────────────────────────────

    func addFilter(propertyId: String) {
        filters.append(BookFilter(id: UUID(), propertyId: propertyId, queryDraft: ""))
    }

    func removeFilter(at index: Int) {
        guard filters.indices.contains(index) else { return }
        filters.remove(at: index)
    }

    func updateFilterValue(id: UUID, value: String) {
        guard let idx = filters.firstIndex(where: { $0.id == id }) else { return }
        filters[idx].queryDraft = value
    }

    /// Entries matching every active filter + the search query. Filter
    /// matching is case-insensitive substring against the cell's
    /// `displayText`. Search runs the same way against every cell.
    var filteredEntries: [EntryFfi] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            // Filters — all must pass.
            for f in filters where !f.queryDraft.isEmpty {
                let cell = entry.values[f.propertyId] ?? .empty
                if !cell.displayText.lowercased().contains(f.queryDraft.lowercased()) {
                    return false
                }
            }
            // Search query — must match at least one cell.
            guard !q.isEmpty else { return true }
            for v in entry.values.values where v.displayText.lowercased().contains(q) {
                return true
            }
            return false
        }
    }

    /// Adopts (or clears with `nil`) the Date column that drives every
    /// row's publish date. The Rust use case backfills / resets all rows
    /// and their backing leaves; reloading keeps the in-memory
    /// entries in sync with the rewritten `published_at` values.
    func setPublishedAtSource(propertyId: String?) {
        tryCatch(into: &errorMessage) {
            _ = try api.setPublishedAtSource(bookId: bookId, propertyId: propertyId)
        }
        load()
    }

    // ── Lookup helpers ───────────────────────────────────────────────────────

    var namePropertyId: String? {
        properties.first {
            if case .title = $0.propertyType { return true }; return false
        }?.id
    }

    func leafId(forEntryId entryId: String) -> String? {
        guard let pageId = pagePropertyId,
              let entry  = entries.first(where: { $0.id == entryId }),
              case .text(let leafId) = entry.values[pageId]
        else { return nil }
        return leafId
    }

    /// Best-effort lookup of the linked leaf's icon for an entry.
    /// Returns `nil` for orphan rows (no linked doc) or unfetched ones —
    /// the row falls back to a generic glyph in that case. Lookup is
    /// cached per-entry to avoid hammering SQLite during scroll, and goes
    /// through the lightweight meta FFI so the block tree never crosses
    /// the boundary just to read an icon.
    func iconForEntry(_ entry: EntryFfi) -> String? {
        if let cached = iconCache[entry.id] { return cached }
        guard let leafId = leafId(forEntryId: entry.id) else {
            iconCache[entry.id] = nil
            return nil
        }
        let icon = (try? api.getLeafMeta(id: leafId))?.icon
        iconCache[entry.id] = icon
        return icon
    }

    // ── Sort cycle (kept from the original VM) ───────────────────────────────

    func cycleSort(propertyId: String) {
        let next: ActiveSort?
        if let current = activeSort, current.propertyId == propertyId {
            next = current.ascending
                ? ActiveSort(propertyId: propertyId, ascending: false)
                : nil
        } else {
            next = ActiveSort(propertyId: propertyId, ascending: true)
        }
        applySort(next)
    }

    private func applySort(_ next: ActiveSort?) {
        // Target the view the user is actually looking at. This used to
        // write to `allViews.first` — so on a book whose List view happens
        // to be at index 0, sorting from the Table view wrote the sort onto
        // List and then re-queried List's ordering. The Table's arrow lit
        // up while its rows were ordered by another view's config.
        guard let viewId = activeViewId else { return }
        let result: ()? = tryCatch(into: &errorMessage) {
            try api.setViewSort(
                bookId: bookId,
                viewId: viewId,
                propertyId: next?.propertyId,
                ascending: next?.ascending ?? true,
            )
        }
        guard result != nil else { return }
        activeSort = next
        activeDateSort = nil
        activeDateSortAscending = nil
        refreshSortedEntries()
    }

    /// Switches the active sort to one of the entry-level timestamp
    /// sources — `created_at` or `published_at`. Pass `nil` to clear.
    func setDateSort(_ kind: DateSortKind?, ascending: Bool) {
        // Same targeting rule as `applySort`.
        guard let viewId = activeViewId else { return }
        let result: ()?
        if let kind {
            result = tryCatch(into: &errorMessage) {
                try api.setViewDateSort(
                    bookId: bookId,
                    viewId: viewId,
                    kind: kind.rawValue,
                    ascending: ascending,
                )
            }
        } else {
            // Clear sort entirely — falls through to the existing
            // property-clear path.
            result = tryCatch(into: &errorMessage) {
                try api.setViewSort(
                    bookId: bookId,
                    viewId: viewId,
                    propertyId: nil,
                    ascending: true,
                )
            }
        }
        guard result != nil else { return }
        activeDateSort = kind
        activeDateSortAscending = kind != nil ? ascending : nil
        if kind != nil {
            // Column sort and date sort are mutually exclusive on
            // the same view — clear the column-sort indicator so the
            // UI doesn't show two highlights at once.
            activeSort = nil
        }
        refreshSortedEntries()
    }

    /// Overrides the publish timestamp of an entry. Empty string =
    /// reset to default (follow `created_at`).
    func updateEntryPublishedAt(entryId: String, isoDate: String) {
        tryCatch(into: &errorMessage) {
            try api.updateEntryPublishedAt(
                bookId: bookId,
                entryId: entryId,
                newPublishedAt: isoDate
            )
        }
        if let idx = entries.firstIndex(where: { $0.id == entryId }) {
            // Rebuild the entry with the new publish stamp so the
            // list rerenders with the updated value without a full
            // SQLite reload.
            var e = entries[idx]
            e = EntryFfi(
                id: e.id,
                createdAt: e.createdAt,
                publishedAt: isoDate,
                values: e.values,
                leafId: e.leafId
            )
            entries[idx] = e
        }
        // If the active sort is a date sort, the order may have
        // changed — re-query.
        if activeDateSort != nil {
            refreshSortedEntries()
        }
    }

    private func refreshSortedEntries() {
        // Must read back from the same view the sort was written to.
        guard let viewId = activeViewId,
              let sorted = tryCatch(into: &errorMessage, {
                  try api.queryBook(bookId: bookId, viewId: viewId)
              })
        else { return }
        entries = sorted
        iconCache.removeAll(keepingCapacity: true)
    }

    // ── Persistence helpers ──────────────────────────────────────────────────

    private func createSystemProp(_ prop: PropertyFfi) {
        guard let json = encode(prop) else { return }
        tryCatch(into: &errorMessage) { try api.addProperty(bookId: bookId, propertyJson: json) }
    }

    private func persist(entryIndex idx: Int) {
        let entry = entries[idx]
        guard let json = encode(entry.values) else { return }
        tryCatch(into: &errorMessage) {
            try api.updateEntry(bookId: bookId, entryId: entry.id, valuesJson: json)
        }
    }

    private func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func fetchDB() -> BookFfi? {
        tryCatch(into: &errorMessage) { try api.getBook(id: bookId) }
    }
}
