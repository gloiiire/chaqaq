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
        pagePropertyId   = db.properties.first(where: { $0.name == pagePropName })?.id

        let allViews = db.views ?? []
        views          = allViews
        primaryViewId  = allViews.first?.id
        if activeViewId == nil || !allViews.contains(where: { $0.id == activeViewId }) {
            activeViewId = allViews.first?.id
        }

        if let view = allViews.first, let s = view.sorts.first, s.source == "Property" {
            activeSort = ActiveSort(propertyId: s.propertyId, ascending: s.order == "Ascending")
        } else {
            activeSort = nil
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
        let view = ViewFfi(id: id, name: name, type: type)
        guard let json = encode(view),
              let _ = tryCatch(into: &errorMessage, {
                  try api.addView(dbId: dbId, viewJson: json)
              })
        else { return }
        views.append(view)
        activeViewId = id
    }

    // ── Header mutations ─────────────────────────────────────────────────────

    func saveTitle(_ plain: String) {
        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        tryCatch(into: &errorMessage) {
            try api.updateDatabaseTitle(id: dbId, newTitle: trimmed)
        }
        titlePlain = trimmed
    }

    func saveDescription(_ plain: String) {
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
    /// cached per-entry to avoid hammering SQLite during scroll.
    func iconForEntry(_ entry: EntryFfi) -> String? {
        if let cached = iconCache[entry.id] { return cached }
        guard let docId = documentId(forEntryId: entry.id) else {
            iconCache[entry.id] = nil
            return nil
        }
        let icon = (try? api.getDocumentJson(id: docId))
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(DocumentFfi.self, from: $0) }?
            .icon
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
        refreshSortedEntries()
    }

    private func refreshSortedEntries() {
        guard let viewId = primaryViewId,
              let json = tryCatch(into: &errorMessage, {
                  try api.queryDatabaseJson(dbId: dbId, viewId: viewId)
              }),
              let data = json.data(using: .utf8),
              let sorted = try? JSONDecoder().decode([EntryFfi].self, from: data)
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
        guard let json = tryCatch(into: &errorMessage, { try api.getDatabaseJson(id: dbId) }),
              let data = json.data(using: .utf8),
              let db   = try? JSONDecoder().decode(DatabaseFfi.self, from: data)
        else { return nil }
        return db
    }
}
