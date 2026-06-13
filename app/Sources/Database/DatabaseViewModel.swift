import SwiftUI

// ── Database view model ───────────────────────────────────────────────────────
//
// State holder for the whole DatabaseView screen :
//   • Doc-like header (cover / icon / title / description).
//   • View switcher (List / Table / Board / Calendar / Gallery).
//   • Per-view group-by, search query, in-memory filters.
//   • Pass-through to the FFI for every mutation.

/// In-memory filter clause. Property + freeform query string ; the VM
/// translates it into a `Contains` condition when running the search
/// path. Persisted filters land in a follow-up PR — for now the user's
/// filter list is session-scoped.
struct DatabaseFilter: Identifiable, Equatable {
    let id: UUID
    var propertyId: String
    var queryDraft: String
}

@MainActor
final class DatabaseViewModel: ObservableObject {
    let dbId: String
    let api: PinkhaApi

    // ── Header ────────────────────────────────────────────────────────────────

    @Published var titlePlain: String = ""
    @Published var descriptionPlain: String = ""
    @Published var cover: String?
    @Published var icon: String?
    /// Read-only flag — propagated from the persisted `Database.locked`.
    /// When `true`, the toolbar's add button is dimmed and every
    /// view component hides its mutation affordances.
    @Published var locked: Bool = false

    // ── Schema + data ─────────────────────────────────────────────────────────

    @Published var properties: [PropertyFfi] = []
    @Published var entries: [EntryFfi] = []
    @Published var views: [ViewFfi] = []
    @Published var errorMessage: String?

    /// UUID of the view currently driving the body. Defaults to the
    /// first view in `views` after load.
    @Published var activeViewId: String?

    /// Currently active sort. `nil` means insertion order.
    @Published private(set) var activeSort: ActiveSort? = nil

    /// UUID of the Date property driving every row's publish date —
    /// mirrors `Database.published_at_source`. `nil` = publish dates
    /// follow `created_at` unless overridden per row.
    @Published private(set) var publishedAtSource: String? = nil

    /// Which entry-level date the active sort is keyed by, if any.
    /// `.none` when no date sort is active (either column sort or
    /// no sort at all). Drives the checkmark in the toolbar's date
    /// sort menu.
    @Published private(set) var activeDateSort: DateSortKind? = nil

    /// Direction of the active date sort. `nil` whenever
    /// `activeDateSort` is `nil`. Kept separate (not folded into the
    /// enum) so the toolbar can match kind and direction independently.
    @Published private(set) var activeDateSortAscending: Bool? = nil

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
    @Published var filters: [DatabaseFilter] = []
    /// Inline search box content. Empty means "no search applied".
    @Published var searchQuery: String = ""
    /// Property used to bucket entries in List / Board / Gallery views.
    /// `nil` means "no grouping" — one synthetic bucket holds all entries.
    @Published var groupByPropertyId: String?
    /// Which group titles the user has collapsed. Session-scoped.
    @Published private(set) var collapsedGroups: Set<String> = []

    struct ActiveSort: Equatable {
        let propertyId: String
        let ascending: Bool
    }

    // ── Hidden plumbing ───────────────────────────────────────────────────────

    /// ID of the hidden system property storing each entry's linked document ID.
    private(set) var pagePropertyId: String? = nil
    private var primaryViewId: String? = nil

    private let pagePropName = "__pinkha_page__"
    private let namePropName = "Name"

    // Cache of doc icons per entry id — lazily filled on demand to keep
    // the list scroll fast.
    private var iconCache: [String: String?] = [:]

    init(dbId: String, api: PinkhaApi) {
        self.dbId = dbId
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

    private func applyDB(_ db: DatabaseFfi) {
        titlePlain       = db.title.map(\.content).joined()
        descriptionPlain = db.description.map(\.content).joined()
        cover            = db.cover
        icon             = db.icon
        locked           = db.locked
        publishedAtSource = db.publishedAtSource
        pagePropertyId   = db.properties.first(where: { $0.name == pagePropName })?.id

        var allViews = db.views ?? []

        // Mobile-first default — every database always has a List view
        // available so users on iPhone never get stuck on the Table
        // layout. Side-effect : creates a Notion-style "List" entry on
        // existing databases imported as Table-only.
        if !allViews.contains(where: { if case .list = $0.type { return true }; return false }) {
            let listId = UUID().uuidString.lowercased()
            let json = newViewJson(id: listId, name: "List", type: .list)
            if tryCatch(into: &errorMessage, {
                try api.addView(dbId: dbId, viewJson: json)
            }) != nil {
                let listView = ViewFfi(id: listId, name: "List", type: .list)
                allViews.insert(listView, at: 0)
            }
        }

        views          = allViews
        primaryViewId  = allViews.first?.id
        // Active view defaults to the List entry — that's the visual
        // default the user expects on mobile, regardless of the order
        // the DB shipped its views in.
        if activeViewId == nil || !allViews.contains(where: { $0.id == activeViewId }) {
            let listFirst = allViews.first(where: {
                if case .list = $0.type { return true }; return false
            })
            activeViewId = listFirst?.id ?? allViews.first?.id
        }

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
            try api.addView(dbId: dbId, viewJson: json)
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
        tryCatch(into: &errorMessage) {
            try api.updateDatabaseTitle(id: dbId, newTitle: trimmed)
        }
        titlePlain = trimmed
    }

    func saveDescription(_ plain: String) {
        guard !locked else { return }
        tryCatch(into: &errorMessage) {
            try api.updateDatabaseDescription(id: dbId, description: plain)
        }
        descriptionPlain = plain
    }

    func saveCover(_ identifier: String?) {
        tryCatch(into: &errorMessage) {
            try api.updateDatabaseCover(id: dbId, cover: identifier)
        }
        cover = identifier
    }

    /// Persists raw image data to the shared covers directory then
    /// updates the DB to reference the resulting file. Mirrors the
    /// document flow so docs and DBs share their cover store.
    func saveCoverFromData(_ data: Data) {
        guard let directory = try? DocumentViewModel.coversDirectory() else { return }
        let filename = "\(UUID().uuidString.lowercased()).jpg"
        let url = directory.appendingPathComponent(filename)
        try? data.write(to: url, options: .atomic)
        saveCover(filename)
    }

    func saveCoverFromFile(_ url: URL) {
        guard let directory = try? DocumentViewModel.coversDirectory(),
              let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let filename = "\(UUID().uuidString.lowercased()).\(ext)"
        let dest = directory.appendingPathComponent(filename)
        try? data.write(to: dest, options: .atomic)
        saveCover(filename)
    }

    func saveIcon(_ identifier: String?) {
        tryCatch(into: &errorMessage) {
            try api.updateDatabaseIcon(id: dbId, icon: identifier)
        }
        icon = identifier
    }

    /// Toggles the read-only flag. Same surface as the document lock —
    /// optimistic local update + best-effort FFI write.
    func toggleLock() {
        let next = !locked
        tryCatch(into: &errorMessage) {
            try api.updateDatabaseLocked(id: dbId, locked: next)
        }
        locked = next
    }

    // ── Entry mutations ──────────────────────────────────────────────────────

    func addEntry() {
        guard let docId  = tryCatch(into: &errorMessage, { try api.createDocument(title: "") }),
              let pageId = pagePropertyId
        else { return }
        var initial: [String: PropertyValueFfi] = [pageId: .text(docId)]
        if let nameId = namePropertyId { initial[nameId] = .title([]) }
        // Pre-seed group-by property so a row created from a group's
        // quick-add lands in the right bucket.
        guard let vJson = encode(initial),
              let entryId = tryCatch(into: &errorMessage, {
                  try api.addEntry(dbId: dbId, valuesJson: vJson)
              })
        else { return }
        entries.append(EntryFfi(id: entryId, createdAt: "", values: initial, documentId: docId))
    }

    /// Same as `addEntry()` but pre-fills the group-by property with
    /// `groupTitle` so the new row materialises inside the right bucket.
    func addEntry(forGroup groupTitle: String) {
        guard let groupProp = groupByPropertyId else { addEntry(); return }
        guard let docId  = tryCatch(into: &errorMessage, { try api.createDocument(title: "") }),
              let pageId = pagePropertyId
        else { return }
        var initial: [String: PropertyValueFfi] = [pageId: .text(docId)]
        if let nameId = namePropertyId { initial[nameId] = .title([]) }
        initial[groupProp] = valueMatching(group: groupTitle)
        guard let vJson = encode(initial),
              let entryId = tryCatch(into: &errorMessage, {
                  try api.addEntry(dbId: dbId, valuesJson: vJson)
              })
        else { return }
        entries.append(EntryFfi(id: entryId, createdAt: "", values: initial, documentId: docId))
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
        if let docId = documentId(forEntryId: id) {
            tryCatch(into: &errorMessage) { try api.deleteDocument(id: docId) }
        }
        tryCatch(into: &errorMessage) { try api.deleteEntry(dbId: dbId, entryId: id) }
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
            try api.renameProperty(dbId: dbId, propertyId: id, newName: name)
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
            try api.deleteProperty(dbId: dbId, propertyId: id)
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
        filters.append(DatabaseFilter(id: UUID(), propertyId: propertyId, queryDraft: ""))
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
    /// and their backing documents; reloading keeps the in-memory
    /// entries in sync with the rewritten `published_at` values.
    func setPublishedAtSource(propertyId: String?) {
        tryCatch(into: &errorMessage) {
            _ = try api.setPublishedAtSource(dbId: dbId, propertyId: propertyId)
        }
        load()
    }

    // ── Lookup helpers ───────────────────────────────────────────────────────

    var namePropertyId: String? {
        properties.first {
            if case .title = $0.propertyType { return true }; return false
        }?.id
    }

    func documentId(forEntryId entryId: String) -> String? {
        guard let pageId = pagePropertyId,
              let entry  = entries.first(where: { $0.id == entryId }),
              case .text(let docId) = entry.values[pageId]
        else { return nil }
        return docId
    }

    /// Best-effort lookup of the linked document's icon for an entry.
    /// Returns `nil` for orphan rows (no linked doc) or unfetched ones —
    /// the row falls back to a generic glyph in that case. Lookup is
    /// cached per-entry to avoid hammering SQLite during scroll, and goes
    /// through the lightweight meta FFI so the block tree never crosses
    /// the boundary just to read an icon.
    func iconForEntry(_ entry: EntryFfi) -> String? {
        if let cached = iconCache[entry.id] { return cached }
        guard let docId = documentId(forEntryId: entry.id) else {
            iconCache[entry.id] = nil
            return nil
        }
        let icon = (try? api.getDocumentMeta(id: docId))?.icon
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
        guard let viewId = primaryViewId else { return }
        let result: ()? = tryCatch(into: &errorMessage) {
            try api.setViewSort(
                dbId: dbId,
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
        guard let viewId = primaryViewId else { return }
        let result: ()?
        if let kind {
            result = tryCatch(into: &errorMessage) {
                try api.setViewDateSort(
                    dbId: dbId,
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
                    dbId: dbId,
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
                dbId: dbId,
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
                documentId: e.documentId
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
        guard let viewId = primaryViewId,
              let sorted = tryCatch(into: &errorMessage, {
                  try api.queryDatabase(dbId: dbId, viewId: viewId)
              })
        else { return }
        entries = sorted
        iconCache.removeAll(keepingCapacity: true)
    }

    // ── Persistence helpers ──────────────────────────────────────────────────

    private func createSystemProp(_ prop: PropertyFfi) {
        guard let json = encode(prop) else { return }
        tryCatch(into: &errorMessage) { try api.addProperty(dbId: dbId, propertyJson: json) }
    }

    private func persist(entryIndex idx: Int) {
        let entry = entries[idx]
        guard let json = encode(entry.values) else { return }
        tryCatch(into: &errorMessage) {
            try api.updateEntry(dbId: dbId, entryId: entry.id, valuesJson: json)
        }
    }

    private func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func fetchDB() -> DatabaseFfi? {
        tryCatch(into: &errorMessage) { try api.getDatabase(id: dbId) }
    }
}
