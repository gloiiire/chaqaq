import Testing
import Foundation
@testable import Pinkha

// Integration tests for the import FFI boundary.
// These tests exercise real SQLite DBs and real FFI calls, but do not hit the
// network — they only validate error handling at the boundary.

@Suite("Import integration — FFI boundary error handling")
struct ImportIntegrationTests {

    // MARK: - Helpers

    private func makeApi() throws -> (PinkhaApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_import_\(UUID().uuidString).db")
        return (try PinkhaApi(dbPath: tmp.path), tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    // MARK: - Bear import — error paths

    @Test func importFromBear_rejects_invalid_path() async throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }

        // /nonexistent.sqlite does not exist — the SQLite extractor must surface a PinkhaError.
        var caught = false
        do {
            _ = try await api.importFromBear(dbPath: "/nonexistent.sqlite")
            Issue.record("Expected PinkhaError for a nonexistent Bear database path, got success instead")
        } catch is PinkhaError {
            caught = true
        } catch {
            Issue.record("Expected PinkhaError, got \(type(of: error)): \(error)")
        }
        #expect(caught, "importFromBear with a nonexistent path must throw PinkhaError")
    }

    @Test func importFromBear_rejects_too_long_path() async throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }

        // 128 KB > MAX_STRING_BYTES (64 KB) — validate_string rejects it as InvalidOperation.
        let hugePath = "/" + String(repeating: "a", count: 128 * 1024)
        do {
            _ = try await api.importFromBear(dbPath: hugePath)
            Issue.record("Expected PinkhaError.InvalidOperation for oversized path")
        } catch PinkhaError.InvalidOperation {
            #expect(Bool(true))  // correct error variant
        } catch {
            Issue.record("Expected PinkhaError.InvalidOperation, got: \(error)")
        }
    }

    @Test func importFromBear_error_is_storage_or_invalid_operation() async throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }

        // Verifies that the error type is a typed PinkhaError and not a crash or unknown error.
        do {
            _ = try await api.importFromBear(dbPath: "/no/such/file.sqlite")
            Issue.record("Expected an error but got success")
        } catch let error as PinkhaError {
            switch error {
            case .Storage, .InvalidOperation:
                break  // expected — validate_string or SQLite open failure
            case .NotFound:
                Issue.record("Unexpected NotFound — import errors should be Storage or InvalidOperation")
            }
        } catch {
            Issue.record("Expected PinkhaError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Notion import — error paths

    @Test func importFromNotion_rejects_too_long_token() async throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }

        // 70_000 chars > MAX_STRING_BYTES (64 KB) — validate_string returns InvalidOperation.
        let hugeToken = String(repeating: "x", count: 70_000)
        do {
            _ = try await api.importFromNotion(token: hugeToken, databaseId: "abc")
            Issue.record("Expected PinkhaError.InvalidOperation for oversized token")
        } catch PinkhaError.InvalidOperation {
            #expect(Bool(true))
        } catch {
            Issue.record("Expected PinkhaError.InvalidOperation, got: \(error)")
        }
    }

    @Test func importFromNotion_rejects_too_long_database_id() async throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }

        let hugeId = String(repeating: "y", count: 70_000)
        do {
            _ = try await api.importFromNotion(token: "secret_test", databaseId: hugeId)
            Issue.record("Expected PinkhaError.InvalidOperation for oversized databaseId")
        } catch PinkhaError.InvalidOperation {
            #expect(Bool(true))
        } catch {
            Issue.record("Expected PinkhaError.InvalidOperation, got: \(error)")
        }
    }

    @Test func importFromNotion_with_empty_token_throws() async throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }

        // An empty token passes length validation but fails at the HTTP/auth layer.
        // The test verifies no crash and that a typed PinkhaError is returned.
        var caught = false
        do {
            _ = try await api.importFromNotion(token: "", databaseId: "abc")
            Issue.record("Expected PinkhaError for an empty token, got success")
        } catch is PinkhaError {
            caught = true
        } catch {
            Issue.record("Expected PinkhaError, got \(type(of: error)): \(error)")
        }
        #expect(caught, "importFromNotion with an empty token must throw PinkhaError")
    }

    @Test func importFromNotion_oversized_token_is_invalid_operation() async throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }

        // Symmetric to importFromBear_rejects_too_long_path but for the Notion extractor.
        let hugeToken = String(repeating: "z", count: 70_000)
        var wasInvalidOperation = false
        do {
            _ = try await api.importFromNotion(token: hugeToken, databaseId: "test")
        } catch PinkhaError.InvalidOperation {
            wasInvalidOperation = true
        } catch {
            Issue.record("Expected PinkhaError.InvalidOperation, got: \(error)")
        }
        #expect(wasInvalidOperation, "validate_string must return InvalidOperation for strings > 64 KB")
    }
}
