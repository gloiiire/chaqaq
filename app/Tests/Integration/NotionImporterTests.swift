import Testing
import Foundation
@testable import Pinkha

// Integration tests for NotionImporter — uses a mock HTTP client to avoid
// real network calls while exercising the full import flow via a real SQLite DB.

// ── Mock HTTP client ──────────────────────────────────────────────────────────
// Routes by HTTP method: GET → schema, POST → query.

private struct MockHTTPClient: NotionHTTPClient {
    let schemaJSON: String
    let queryJSON: String

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let json = request.httpMethod == "POST" ? queryJSON : schemaJSON
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
    }
}

// ── Fixtures ──────────────────────────────────────────────────────────────────

private let schemaJSON = """
{
  "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
  "title": [{"plain_text": "My Test DB"}],
  "properties": {
    "Name": {"id": "title", "name": "Name", "type": "title"},
    "Status": {
      "id": "s1", "name": "Status", "type": "select",
      "select": {"options": [{"name": "Todo","color":"red"},{"name":"Done","color":"green"}]}
    },
    "Tags": {
      "id": "t1", "name": "Tags", "type": "multi_select",
      "multi_select": {"options": [{"name":"swift","color":"blue"},{"name":"rust","color":"orange"}]}
    },
    "Due": {"id": "d1", "name": "Due", "type": "date"}
  }
}
"""

private let queryJSON = """
{
  "results": [
    {
      "id": "page1",
      "properties": {
        "Name": {
          "type": "title",
          "title": [{"plain_text": "First entry"}]
        },
        "Status": {
          "type": "select",
          "select": {"name": "Todo"}
        },
        "Tags": {
          "type": "multi_select",
          "multi_select": [{"name": "swift"}, {"name": "rust"}]
        },
        "Due": {
          "type": "date",
          "date": {"start": "2026-06-01"}
        }
      }
    },
    {
      "id": "page2",
      "properties": {
        "Name": {
          "type": "title",
          "title": [{"plain_text": "Second entry"}]
        },
        "Status": {"type": "select", "select": null},
        "Tags": {"type": "multi_select", "multi_select": []},
        "Due": {"type": "date", "date": null}
      }
    }
  ],
  "has_more": false,
  "next_cursor": null
}
"""

// ── Tests ─────────────────────────────────────────────────────────────────────

@MainActor
@Suite("NotionImporter — integration via mock HTTP + real SQLite")
struct NotionImporterTests {

    private func makeEnv() throws -> (NotionImporter, PinkhaApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_notion_\(UUID().uuidString).db")
        let api = try PinkhaApi(dbPath: tmp.path)
        let importer = NotionImporter()
        let mock = MockHTTPClient(schemaJSON: schemaJSON, queryJSON: queryJSON)
        importer.makeHTTP = { _ in mock }
        return (importer, api, tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    // ── Full import flow ──────────────────────────────────────────────────────

    @Test func importCreatesDatabase() async throws {
        let (importer, api, url) = try makeEnv(); defer { cleanup(url) }
        importer.start(token: "secret_test", notionUrl: "aaaabbbbccccddddeeee", api: api)

        // Poll until done (async)
        var waited = 0
        while !importer.isDone, waited < 50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }

        guard case .done(let result) = importer.progress else {
            if case .failed(let msg) = importer.progress { Issue.record("Import failed: \(msg)") }
            Issue.record("Import did not complete"); return
        }
        #expect(result.databaseTitle == "My Test DB")
        #expect(result.entryCount == 2)
        #expect(!result.databaseId.isEmpty)
    }

    @Test func importedDatabaseAppearsInList() async throws {
        let (importer, api, url) = try makeEnv(); defer { cleanup(url) }
        importer.start(token: "secret_test", notionUrl: "aaaabbbbccccddddeeee", api: api)

        var waited = 0
        while !importer.isDone, waited < 50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }

        guard case .done(let result) = importer.progress else { return }
        let dbs = try api.listDatabases()
        #expect(dbs.contains { $0.id == result.databaseId })
    }

    @Test func importedEntriesHaveLinkedDocuments() async throws {
        let (importer, api, url) = try makeEnv(); defer { cleanup(url) }
        importer.start(token: "secret_test", notionUrl: "aaaabbbbccccddddeeee", api: api)

        var waited = 0
        while !importer.isDone, waited < 50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }

        guard case .done(let result) = importer.progress else { return }

        // Load via VM to verify entries and their linked docs
        let vm = DatabaseViewModel(dbId: result.databaseId, api: api)
        vm.load()
        #expect(vm.entries.count == 2)

        for entry in vm.entries {
            let docId = vm.documentId(forEntryId: entry.id)
            #expect(docId != nil, "Entry \(entry.id) should have a linked document")
            #expect(throws: Never.self) { _ = try api.getDocumentJson(id: docId!) }
        }
    }

    @Test func importedPropertiesMatchNotionSchema() async throws {
        let (importer, api, url) = try makeEnv(); defer { cleanup(url) }
        importer.start(token: "secret_test", notionUrl: "aaaabbbbccccddddeeee", api: api)

        var waited = 0
        while !importer.isDone, waited < 50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }

        guard case .done(let result) = importer.progress else { return }

        let vm = DatabaseViewModel(dbId: result.databaseId, api: api)
        vm.load()

        let names = vm.properties.map(\.name)
        // Name (Title) is always first
        #expect(names.first == "Name")
        #expect(names.contains("Status"))
        #expect(names.contains("Tags"))
        #expect(names.contains("Due"))

        let statusProp = vm.properties.first { $0.name == "Status" }!
        if case .selection(let opts) = statusProp.propertyType {
            #expect(opts.contains("Todo"))
            #expect(opts.contains("Done"))
        } else {
            Issue.record("Status should be .selection")
        }

        let tagsProp = vm.properties.first { $0.name == "Tags" }!
        if case .selectionMultiple(let opts) = tagsProp.propertyType {
            #expect(opts.contains("swift"))
            #expect(opts.contains("rust"))
        } else {
            Issue.record("Tags should be .selectionMultiple")
        }

        let dueProp = vm.properties.first { $0.name == "Due" }!
        #expect(dueProp.propertyType == .date)
    }

    @Test func importedFirstEntryHasCorrectValues() async throws {
        let (importer, api, url) = try makeEnv(); defer { cleanup(url) }
        importer.start(token: "secret_test", notionUrl: "aaaabbbbccccddddeeee", api: api)

        var waited = 0
        while !importer.isDone, waited < 50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }

        guard case .done(let result) = importer.progress else { return }

        let vm = DatabaseViewModel(dbId: result.databaseId, api: api)
        vm.load()

        let statusProp = vm.properties.first { $0.name == "Status" }!
        let dueProp    = vm.properties.first { $0.name == "Due" }!
        let tagsProp   = vm.properties.first { $0.name == "Tags" }!

        // Find "First entry"
        let nameId = vm.properties.first { if case .title = $0.propertyType { return true }; return false }!.id
        guard let first = vm.entries.first(where: {
            if case .title(let spans) = $0.values[nameId] { return spans.first?.content == "First entry" }
            return false
        }) else { Issue.record("Could not find 'First entry'"); return }

        #expect(first.values[statusProp.id] == .selection("Todo"))
        #expect(first.values[tagsProp.id] == .selectionMultiple(["swift", "rust"]))
        #expect(first.values[dueProp.id] == .date("2026-06-01"))
    }

    @Test func importedSecondEntryHasEmptyOptionalValues() async throws {
        let (importer, api, url) = try makeEnv(); defer { cleanup(url) }
        importer.start(token: "secret_test", notionUrl: "aaaabbbbccccddddeeee", api: api)

        var waited = 0
        while !importer.isDone, waited < 50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }

        guard case .done(let result) = importer.progress else { return }

        let vm = DatabaseViewModel(dbId: result.databaseId, api: api)
        vm.load()

        let statusProp = vm.properties.first { $0.name == "Status" }!
        let nameId = vm.properties.first { if case .title = $0.propertyType { return true }; return false }!.id
        guard let second = vm.entries.first(where: {
            if case .title(let spans) = $0.values[nameId] { return spans.first?.content == "Second entry" }
            return false
        }) else { Issue.record("Could not find 'Second entry'"); return }

        // select: null → .selection(nil)
        #expect(second.values[statusProp.id] == .selection(nil))
    }

    @Test func importProgressGoesIdleToDoneWithoutError() async throws {
        let (importer, api, url) = try makeEnv(); defer { cleanup(url) }

        if case .idle = importer.progress {} else { Issue.record("Should start idle") }

        importer.start(token: "secret_test", notionUrl: "aaaabbbbccccddddeeee", api: api)

        var waited = 0
        while !importer.isDone, waited < 50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }

        if case .failed(let msg) = importer.progress { Issue.record("Unexpected failure: \(msg)") }
        #expect(importer.isDone)
    }
}
