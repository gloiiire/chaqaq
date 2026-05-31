import Foundation

// ── Notion API v1 client ───────────────────────────────────────────────────────

protocol NotionHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NotionHTTPClient {}

// ── Error ─────────────────────────────────────────────────────────────────────

enum NotionAPIError: LocalizedError {
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .http(let s, let m): return "Notion \(s): \(m)"
        }
    }
}

// ── Response models ───────────────────────────────────────────────────────────

struct NotionDatabaseSchema: Decodable {
    let id: String
    let title: [NotionRichText]
    let properties: [String: NotionPropertyDef]

    var titlePlain: String { title.map(\.plainText).joined() }
}

struct NotionRichText: Decodable {
    let plainText: String
    enum CodingKeys: String, CodingKey { case plainText = "plain_text" }
}

struct NotionPropertyDef: Decodable {
    let id: String
    let name: String
    let type: String
    let select: NotionSelectConfig?
    let multiSelect: NotionMultiSelectConfig?

    enum CodingKeys: String, CodingKey {
        case id, name, type, select
        case multiSelect = "multi_select"
    }
}

struct NotionSelectConfig: Decodable {
    let options: [NotionOption]
}

struct NotionMultiSelectConfig: Decodable {
    let options: [NotionOption]
}

struct NotionOption: Decodable {
    let name: String
    let color: String?
}

struct NotionQueryResponse: Decodable {
    let results: [NotionPageResult]
    let hasMore: Bool
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case results
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }
}

struct NotionPageResult: Decodable {
    let id: String
    let properties: [String: NotionPagePropValue]
}

// Discriminated union — decoded via `type` field.
enum NotionPagePropValue: Decodable {
    case title([NotionRichText])
    case richText([NotionRichText])
    case number(Double?)
    case select(String?)         // name of selected option, or nil
    case multiSelect([String])   // names of selected options
    case date(String?)           // ISO-8601 start date, or nil
    case checkbox(Bool)
    case url(String?)
    case unknown

    var plainText: String {
        switch self {
        case .title(let items):       return items.map(\.plainText).joined()
        case .richText(let items):    return items.map(\.plainText).joined()
        case .number(let n):          return n.map { "\($0)" } ?? ""
        case .select(let name):       return name ?? ""
        case .multiSelect(let names): return names.joined(separator: ", ")
        case .date(let s):            return s ?? ""
        case .checkbox(let b):        return b ? "true" : "false"
        case .url(let u):             return u ?? ""
        case .unknown:                return ""
        }
    }

    private struct DynKey: CodingKey {
        var stringValue: String; var intValue: Int?
        init(_ s: String) { stringValue = s; intValue = nil }
        init?(stringValue s: String) { self.init(s) }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynKey.self)
        let type = try c.decode(String.self, forKey: DynKey("type"))
        switch type {
        case "title":
            self = .title(try c.decode([NotionRichText].self, forKey: DynKey("title")))
        case "rich_text":
            self = .richText(try c.decode([NotionRichText].self, forKey: DynKey("rich_text")))
        case "number":
            self = .number(try c.decodeIfPresent(Double.self, forKey: DynKey("number")))
        case "select":
            struct SV: Decodable { let name: String? }
            let sv = try c.decodeIfPresent(SV.self, forKey: DynKey("select"))
            self = .select(sv?.name)
        case "multi_select":
            struct MSItem: Decodable { let name: String }
            let items = try c.decode([MSItem].self, forKey: DynKey("multi_select"))
            self = .multiSelect(items.map(\.name))
        case "date":
            struct DV: Decodable { let start: String? }
            let dv = try c.decodeIfPresent(DV.self, forKey: DynKey("date"))
            self = .date(dv?.start)
        case "checkbox":
            self = .checkbox(try c.decode(Bool.self, forKey: DynKey("checkbox")))
        case "url":
            self = .url(try c.decodeIfPresent(String.self, forKey: DynKey("url")))
        default:
            self = .unknown
        }
    }
}

// ── Client ────────────────────────────────────────────────────────────────────

struct NotionAPIClient {
    let token: String
    let http: NotionHTTPClient

    init(token: String, http: NotionHTTPClient = URLSession.shared) {
        self.token = token
        self.http = http
    }

    private static let base = "https://api.notion.com/v1"
    private static let version = "2022-06-28"

    func getDatabase(id: String) async throws -> NotionDatabaseSchema {
        let (data, resp) = try await http.data(for: makeRequest("/databases/\(id)"))
        try checkResponse(data, resp)
        return try JSONDecoder().decode(NotionDatabaseSchema.self, from: data)
    }

    func queryDatabase(id: String, startCursor: String? = nil) async throws -> NotionQueryResponse {
        var body: [String: String] = [:]
        if let cursor = startCursor { body["start_cursor"] = cursor }
        let bodyData = try JSONEncoder().encode(body)
        let (data, resp) = try await http.data(for: makeRequest("/databases/\(id)/query", method: "POST", body: bodyData))
        try checkResponse(data, resp)
        return try JSONDecoder().decode(NotionQueryResponse.self, from: data)
    }

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: "\(Self.base)\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.version, forHTTPHeaderField: "Notion-Version")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private func checkResponse(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        struct ErrBody: Decodable { let message: String }
        let msg = (try? JSONDecoder().decode(ErrBody.self, from: data))?.message ?? "HTTP \(http.statusCode)"
        throw NotionAPIError.http(status: http.statusCode, message: msg)
    }
}
