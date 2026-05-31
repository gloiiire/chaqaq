import Foundation

// ── Import result ─────────────────────────────────────────────────────────────

struct ImportResult {
    let databaseId: String
    let databaseTitle: String
    let entryCount: Int
}

// ── Notion → Pinkha importer ──────────────────────────────────────────────────

@MainActor
final class NotionImporter: ObservableObject {

    enum Progress {
        case idle
        case running(message: String)
        case done(ImportResult)
        case failed(String)
    }

    @Published var progress: Progress = .idle

    // Injected for tests — defaults to URLSession.shared.
    var makeHTTP: (String) -> NotionHTTPClient = { _ in URLSession.shared }

    var isDone: Bool { if case .done = progress { return true }; return false }

    func start(token: String, notionUrl: String, api: PinkhaApi) {
        Task { await run(token: token, notionUrl: notionUrl, api: api) }
    }

    func reset() { progress = .idle }

    // ── Core ──────────────────────────────────────────────────────────────────

    private func run(token: String, notionUrl: String, api: PinkhaApi) async {
        let dbId = extractId(from: notionUrl)
        let client = NotionAPIClient(token: token, http: makeHTTP(token))

        do {
            // 1. Schema
            progress = .running(message: "Fetching database schema…")
            let schema = try await client.getDatabase(id: dbId)
            let dbTitle = schema.titlePlain

            // 2. Create Pinkha database
            progress = .running(message: "Creating \"\(dbTitle)\"…")
            let pinkhaDbId = try api.createDatabase(title: dbTitle)

            // 3. Bootstrap system properties (mirrors DatabaseViewModel.load)
            let pageId = UUID().uuidString.lowercased()
            let nameId = UUID().uuidString.lowercased()
            try api.addProperty(dbId: pinkhaDbId, propertyJson: encode(
                PropertyFfi(id: pageId, name: "__pinkha_page__", propertyType: .text)))
            try api.addProperty(dbId: pinkhaDbId, propertyJson: encode(
                PropertyFfi(id: nameId, name: "Name", propertyType: .title)))

            // 4. User-visible properties from Notion schema
            let propMap = try buildPropMap(schema: schema, dbId: pinkhaDbId, api: api)

            // 5. Import pages with pagination
            progress = .running(message: "Importing entries…")
            var cursor: String? = nil
            var total = 0
            repeat {
                let page = try await client.queryDatabase(id: dbId, startCursor: cursor)
                for notionPage in page.results {
                    try importPage(notionPage, nameId: nameId, pageId: pageId, propMap: propMap, dbId: pinkhaDbId, api: api)
                    total += 1
                    if total % 10 == 0 {
                        progress = .running(message: "Importing entries… (\(total))")
                    }
                }
                cursor = page.hasMore ? page.nextCursor : nil
            } while cursor != nil

            progress = .done(ImportResult(databaseId: pinkhaDbId, databaseTitle: dbTitle, entryCount: total))
        } catch {
            progress = .failed(error.localizedDescription)
        }
    }

    // ── Property schema mapping ───────────────────────────────────────────────

    // Creates Pinkha properties for each non-title Notion property.
    // Returns a map: Notion property name → Pinkha property ID.
    private func buildPropMap(
        schema: NotionDatabaseSchema,
        dbId: String,
        api: PinkhaApi
    ) throws -> [String: String] {
        var map: [String: String] = [:]
        for (name, def) in schema.properties where def.type != "title" {
            let id = UUID().uuidString.lowercased()
            try api.addProperty(dbId: dbId, propertyJson: encode(
                PropertyFfi(id: id, name: name, propertyType: mapType(def))))
            map[name] = id
        }
        return map
    }

    // Maps a Notion property definition to a Pinkha type.
    func mapType(_ def: NotionPropertyDef) -> PropertyTypeFfi {
        switch def.type {
        case "title":        return .title
        case "number":       return .number
        case "checkbox":     return .checkbox
        case "date":         return .date
        case "url":          return .url
        case "select":       return .selection(def.select?.options.map(\.name) ?? [])
        case "multi_select": return .selectionMultiple(def.multiSelect?.options.map(\.name) ?? [])
        default:             return .text
        }
    }

    // Maps a Notion page property value to a Pinkha value.
    func mapValue(_ val: NotionPagePropValue) -> PropertyValueFfi? {
        switch val {
        case .title(let items):
            return .title(items.map { InlineTextFfi(content: $0.plainText, styles: []) })
        case .richText(let items):
            let text = items.map(\.plainText).joined()
            return text.isEmpty ? .empty : .text(text)
        case .number(let n):
            return n.map { .number($0) } ?? .empty
        case .select(let name):
            return .selection(name)
        case .multiSelect(let names):
            return names.isEmpty ? .empty : .selectionMultiple(names)
        case .date(let start):
            return start.map { .date($0) } ?? .empty
        case .checkbox(let b):
            return .checkbox(b)
        case .url(let u):
            return u.map { .url($0) } ?? .empty
        case .unknown:
            return nil
        }
    }

    // ── Page import ───────────────────────────────────────────────────────────

    private func importPage(
        _ page: NotionPageResult,
        nameId: String,
        pageId: String,
        propMap: [String: String],
        dbId: String,
        api: PinkhaApi
    ) throws {
        var values: [String: PropertyValueFfi] = [:]

        // Title property → Name column
        var plainTitle = "Untitled"
        for propVal in page.properties.values {
            if case .title(let items) = propVal {
                plainTitle = items.map(\.plainText).joined()
                values[nameId] = .title(items.map { InlineTextFfi(content: $0.plainText, styles: []) })
                break
            }
        }

        // Create linked document
        let docId = try api.createDocument(title: plainTitle)
        values[pageId] = .text(docId)

        // Other properties
        for (propName, propVal) in page.properties {
            guard let pinkhaPropId = propMap[propName] else { continue }
            if let pv = mapValue(propVal) { values[pinkhaPropId] = pv }
        }

        try api.addEntry(dbId: dbId, valuesJson: encode(values))
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    // Extracts a 32-char hex database ID from a Notion URL, path, or bare ID.
    // Handles: "https://notion.so/Title-<32hex>", bare UUID with dashes, bare 32-char hex.
    func extractId(from input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://www.notion.so/", "https://notion.so/"] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        }
        s = s.components(separatedBy: "?")[0]
        s = s.components(separatedBy: "/").last ?? s
        // Look for a 32-char hex sequence (UUID without dashes, possibly after a title slug dash)
        if let range = s.range(of: "[0-9a-fA-F]{32}", options: .regularExpression) {
            return String(s[range])
        }
        // Fallback: strip dashes (bare dashed UUID input)
        return s.replacingOccurrences(of: "-", with: "")
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }
}
