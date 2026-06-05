import SwiftUI

// ── Database view model ───────────────────────────────────────────────────────

@MainActor
final class DatabaseViewModel: ObservableObject {
    let dbId: String
    let api: PinkhaApi

    @Published var titlePlain: String = ""
    /// User-visible columns. Title-type property is always first.
    @Published var properties: [PropertyFfi] = []
    @Published var entries: [EntryFfi] = []
    @Published var errorMessage: String?
    /// Currently active sort. `nil` means no column is sorted — display
    /// entries in their natural insertion order.
    @Published private(set) var activeSort: ActiveSort? = nil

    /// (propertyId, ascending) snapshot used to drive both the header arrow
    /// indicator and the cycling logic on tap.
    struct ActiveSort: Equatable {
        let propertyId: String
        let ascending: Bool
    }

    /// ID of the hidden system property storing each entry's linked document ID.
    private(set) var pagePropertyId: String? = nil
    /// ID of the database's primary (default "Table") view — `set_view_sort`
    /// targets this one.
    private var primaryViewId: String? = nil

    private let pagePropName = "__pinkha_page__"
    private let namePropName = "Name"

    init(dbId: String, api: PinkhaApi) {
        self.dbId = dbId
        self.api = api
    }

    // ── Load ──────────────────────────────────────────────────────────────────

    func load() {
        guard let db = fetchDB() else { return }

        var needsReload = false

        // Ensure hidden page-link property exists.
        if let pp = db.properties.first(where: { $0.name == pagePropName }) {
            pagePropertyId = pp.id
        } else {
            let id = UUID().uuidString.lowercased()
            createSystemProp(PropertyFfi(id: id, name: pagePropName, propertyType: .text))
            pagePropertyId = id
            needsReload = true
        }

        // Ensure a visible Name (Title) column exists.
        let visible = db.properties.filter { $0.name != pagePropName }
        let hasTitle = visible.contains { if case .title = $0.propertyType { return true }; return false }
        if !hasTitle {
            let id = UUID().uuidString.lowercased()
            createSystemProp(PropertyFfi(id: id, name: namePropName, propertyType: .title))
            needsReload = true
        }

        applyDB(needsReload ? (fetchDB() ?? db) : db)
    }

    // ── CRUD ──────────────────────────────────────────────────────────────────

    /// Creates a blank document and a linked entry. Title is empty on creation.
    func addEntry() {
        guard let docId  = tryCatch(into: &errorMessage, { try api.createDocument(title: "") }),
              let pageId = pagePropertyId
        else { return }

        var initial: [String: PropertyValueFfi] = [pageId: .text(docId)]
        if let nameId = namePropertyId { initial[nameId] = .title([]) }

        guard let vJson = encode(initial),
              let entryId = tryCatch(into: &errorMessage, { try api.addEntry(dbId: dbId, valuesJson: vJson) })
        else { return }

        entries.append(EntryFfi(id: entryId, createdAt: "", values: initial, documentId: docId))
    }

    /// Deletes the entry and its linked document.
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

    /// Adds a user-visible property column.
    func addProperty(name: String, type: PropertyTypeFfi) {
        let prop = PropertyFfi(id: UUID().uuidString.lowercased(), name: name, propertyType: type)
        createSystemProp(prop)
        properties.append(prop)
    }

    func renameProperty(id: String, newName: String) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        tryCatch(into: &errorMessage) { try api.renameProperty(dbId: dbId, propertyId: id, newName: name) }
        if let i = properties.firstIndex(where: { $0.id == id }) {
            properties[i] = PropertyFfi(id: id, name: name, propertyType: properties[i].propertyType)
        }
    }

    /// Deletes a user-visible property. Title columns cannot be deleted.
    func deleteProperty(id: String) {
        guard let prop = properties.first(where: { $0.id == id }),
              !(prop.propertyType == .title)
        else { return }
        tryCatch(into: &errorMessage) { try api.deleteProperty(dbId: dbId, propertyId: id) }
        properties.removeAll { $0.id == id }
        for i in entries.indices { entries[i].values.removeValue(forKey: id) }
    }

    /// Returns the linked document ID for an entry, or `nil` if not yet set.
    func documentId(forEntryId entryId: String) -> String? {
        guard let pageId = pagePropertyId,
              let entry  = entries.first(where: { $0.id == entryId }),
              case .text(let docId) = entry.values[pageId]
        else { return nil }
        return docId
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private var namePropertyId: String? {
        properties.first { if case .title = $0.propertyType { return true }; return false }?.id
    }

    private func fetchDB() -> DatabaseFfi? {
        guard let json = tryCatch(into: &errorMessage, { try api.getDatabaseJson(id: dbId) }),
              let data = json.data(using: .utf8),
              let db   = try? JSONDecoder().decode(DatabaseFfi.self, from: data)
        else { return nil }
        return db
    }

    private func applyDB(_ db: DatabaseFfi) {
        titlePlain    = db.title.map(\.content).joined()
        pagePropertyId = db.properties.first(where: { $0.name == pagePropName })?.id
        let views = db.views ?? []
        primaryViewId  = views.first?.id
        // Reflect the currently persisted sort, if any. The "Property" source
        // is the only one we drive from the column header tap — other
        // source values (e.g. Created) belong to richer sort UIs we don't
        // surface yet.
        if let view = views.first, let s = view.sorts.first, s.source == "Property" {
            activeSort = ActiveSort(propertyId: s.propertyId, ascending: s.order == "Ascending")
        } else {
            activeSort = nil
        }

        var visible = db.properties.filter { $0.name != pagePropName }
        // Title property always first.
        visible.sort {
            if case .title = $0.propertyType { return true }
            if case .title = $1.propertyType { return false }
            return false
        }
        properties = visible
        entries    = db.entries

        // Apply server-side sort to the in-memory entries.
        refreshSortedEntries()
    }

    // ── Sort ──────────────────────────────────────────────────────────────────

    /// Cycles the sort on a column header: none → asc → desc → none.
    /// Sorting another column resets to that column's asc.
    func cycleSort(propertyId: String) {
        let next: ActiveSort?
        if let current = activeSort, current.propertyId == propertyId {
            // Same column — advance through the cycle.
            next = current.ascending
                ? ActiveSort(propertyId: propertyId, ascending: false)
                : nil
        } else {
            // Different column (or no active sort) — start ascending.
            next = ActiveSort(propertyId: propertyId, ascending: true)
        }
        applySort(next)
    }

    /// Persists `next` to the primary view via the FFI and refreshes
    /// `entries` from a fresh query result. No client-side sorting — the
    /// Rust query honours the sort and returns the right order.
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

    /// Re-queries the primary view and replaces `entries` with the sorted
    /// result. Falls back to the unsorted in-memory list on failure so the
    /// UI never goes blank.
    private func refreshSortedEntries() {
        guard let viewId = primaryViewId,
              let json = tryCatch(into: &errorMessage, {
                  try api.queryDatabaseJson(dbId: dbId, viewId: viewId)
              }),
              let data = json.data(using: .utf8),
              let sorted = try? JSONDecoder().decode([EntryFfi].self, from: data)
        else { return }
        entries = sorted
    }

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
}

