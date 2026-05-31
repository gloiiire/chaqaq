import Testing
import Foundation
@testable import Pinkha

@Suite("Concurrence — écritures simultanées via le retry SQLite")
struct ConcurrencyTests {

    private func makeApi() throws -> (PinkhaApi, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_conc_\(UUID().uuidString).db")
        return (try PinkhaApi(dbPath: tmp.path), tmp)
    }

    @Test func concurrentDocumentCreationsAllSucceed() async throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }

        // 20 créations en parallèle. Le retry SQLite + WAL doit absorber les contentions.
        let count = 20
        await withTaskGroup(of: String?.self) { group in
            for i in 0..<count {
                group.addTask {
                    return try? api.createDocument(title: "Doc \(i)")
                }
            }
            var ids: [String] = []
            for await result in group {
                if let id = result { ids.append(id) }
            }
            #expect(ids.count == count,
                    "toutes les créations concurrentes doivent réussir grâce au retry")
        }
        #expect(try api.listDocuments().count == count)
    }

    @Test func concurrentReadsWhileWriting() async throws {
        let (api, url) = try makeApi()
        defer { try? FileManager.default.removeItem(at: url) }
        // Seed
        for i in 0..<5 {
            _ = try api.createDocument(title: "Pre \(i)")
        }

        // Lectures + écritures simultanées.
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<10 {
                group.addTask { (try? api.createDocument(title: "W \(i)")) != nil }
                group.addTask { (try? api.listDocuments()) != nil }
            }
            var successes = 0
            for await ok in group { if ok { successes += 1 } }
            #expect(successes == 20, "les 20 opérations concurrentes doivent réussir")
        }
    }
}
