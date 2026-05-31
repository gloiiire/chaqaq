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

    /// ID of the hidden system property storing each entry's linked document ID.
    private(set) var pagePropertyId: String? = nil

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

        entries.append(EntryFfi(id: entryId, createdAt: "", values: initial))
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

        var visible = db.properties.filter { $0.name != pagePropName }
        // Title property always first.
        visible.sort {
            if case .title = $0.propertyType { return true }
            if case .title = $1.propertyType { return false }
            return false
        }
        properties = visible
        entries    = db.entries
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

