import SwiftUI

// ── Database view model ───────────────────────────────────────────────────────

@MainActor
final class DatabaseViewModel: ObservableObject {
    let dbId: String
    let api: PinkhaApi

    @Published var titlePlain: String = ""
    @Published var properties: [PropertyFfi] = []  // user-visible columns only
    @Published var entries: [EntryFfi] = []
    @Published var errorMessage: String?

    // ID of the hidden system property that stores each entry's linked document ID.
    // Created automatically on first load if absent.
    private(set) var pagePropertyId: String? = nil

    // Reserved name for the hidden page-link property — never shown as a column.
    private let pagePropName = "__pinkha_page__"

    init(dbId: String, api: PinkhaApi) {
        self.dbId = dbId
        self.api = api
    }

    func load() {
        guard let json = tryCatch(into: &errorMessage, { try api.getDatabaseJson(id: dbId) }),
              let data = json.data(using: .utf8),
              let db   = try? JSONDecoder().decode(DatabaseFfi.self, from: data)
        else { return }

        titlePlain = db.title.map(\.content).joined()

        // Locate or create the hidden page-link property.
        if let pp = db.properties.first(where: { $0.name == pagePropName }) {
            pagePropertyId = pp.id
        } else {
            let newId = UUID().uuidString.lowercased()
            let prop  = PropertyFfi(id: newId, name: pagePropName, propertyType: .text)
            if let propData = try? JSONEncoder().encode(prop),
               let propJson = String(data: propData, encoding: .utf8) {
                tryCatch(into: &errorMessage) { try api.addProperty(dbId: dbId, propertyJson: propJson) }
                pagePropertyId = newId
            }
        }

        // Expose only user-visible properties (hide the page-link column).
        properties = db.properties.filter { $0.name != pagePropName }
        entries    = db.entries
    }

    /// Creates a blank document, then creates a linked database entry.
    func addEntry() {
        guard let docId  = tryCatch(into: &errorMessage, { try api.createDocument(title: "") }),
              let pageId = pagePropertyId
        else { return }

        var initial: [String: PropertyValueFfi] = [pageId: .text(docId)]
        guard let valData    = try? JSONEncoder().encode(initial),
              let valuesJson = String(data: valData, encoding: .utf8),
              let entryId    = tryCatch(into: &errorMessage, { try api.addEntry(dbId: dbId, valuesJson: valuesJson) })
        else { return }

        entries.append(EntryFfi(id: entryId, createdAt: "", values: [pageId: .text(docId)]))
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

    func addProperty(name: String, type: PropertyTypeFfi) {
        // Lowercase to match Rust's Uuid::to_string() serialization.
        let prop = PropertyFfi(id: UUID().uuidString.lowercased(), name: name, propertyType: type)
        guard let data = try? JSONEncoder().encode(prop),
              let json = String(data: data, encoding: .utf8) else { return }
        tryCatch(into: &errorMessage) { try api.addProperty(dbId: dbId, propertyJson: json) }
        properties.append(prop)
    }

    func deleteProperty(id: String) {
        tryCatch(into: &errorMessage) { try api.deleteProperty(dbId: dbId, propertyId: id) }
        properties.removeAll { $0.id == id }
        for i in entries.indices { entries[i].values.removeValue(forKey: id) }
    }

    /// Returns the linked document ID for an entry, or `nil` if the entry has no page.
    func documentId(forEntryId entryId: String) -> String? {
        guard let pageId = pagePropertyId,
              let entry  = entries.first(where: { $0.id == entryId }),
              case .text(let docId) = entry.values[pageId]
        else { return nil }
        return docId
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private func persist(entryIndex idx: Int) {
        let entry = entries[idx]
        guard let data = try? JSONEncoder().encode(entry.values),
              let json = String(data: data, encoding: .utf8) else { return }
        tryCatch(into: &errorMessage) {
            try api.updateEntry(dbId: dbId, entryId: entry.id, valuesJson: json)
        }
    }
}
