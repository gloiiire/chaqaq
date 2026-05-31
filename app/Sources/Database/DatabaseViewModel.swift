import SwiftUI

// ── Database view model ───────────────────────────────────────────────────────

@MainActor
final class DatabaseViewModel: ObservableObject {
    let dbId: String
    private let api: PinkhaApi

    @Published var titlePlain: String = ""
    @Published var properties: [PropertyFfi] = []
    @Published var entries: [EntryFfi] = []
    @Published var errorMessage: String?

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
        properties = db.properties
        entries    = db.entries
    }

    func addEntry() {
        guard let entryId = tryCatch(into: &errorMessage, { try api.addEntry(dbId: dbId, valuesJson: "{}") })
        else { return }
        entries.append(EntryFfi(id: entryId, createdAt: "", values: [:]))
    }

    func deleteEntry(id: String) {
        tryCatch(into: &errorMessage) { try api.deleteEntry(dbId: dbId, entryId: id) }
        entries.removeAll { $0.id == id }
    }

    func updateCell(entryId: String, propertyId: String, value: PropertyValueFfi) {
        guard let idx = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[idx].values[propertyId] = value
        persist(entryIndex: idx)
    }

    func addProperty(name: String, type: PropertyTypeFfi) {
        // Use lowercase to match Rust's Uuid serialization (to_string() outputs lowercase).
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
