import Testing
import SwiftUI
@testable import Chaqaq

@Suite("ChaqaqError — messages utilisateur et récupérabilité")
struct ChaqaqErrorUXTests {

    @Test func notFoundProducesFriendlyMessage() {
        let msg = ChaqaqError.NotFound(id: "abc").userMessage
        #expect(msg.contains("introuvable"))
    }

    @Test func invalidOperationIncludesDetail() {
        let msg = ChaqaqError.InvalidOperation(detail: "UUID invalide").userMessage
        #expect(msg.contains("UUID invalide"))
    }

    @Test func storageMessageSuggestsRetry() {
        let msg = ChaqaqError.Storage(detail: "lock").userMessage
        #expect(msg.contains("Réessaie") || msg.contains("réessaie"))
    }

    @Test func onlyStorageIsRecoverable() {
        #expect(ChaqaqError.Storage(detail: "x").isRecoverable)
        #expect(!ChaqaqError.NotFound(id: "x").isRecoverable)
        #expect(!ChaqaqError.InvalidOperation(detail: "x").isRecoverable)
    }
}

@Suite("ActionRepeater — timer de répétition")
struct ActionRepeaterTests {

    @Test func notActiveWhenJustCreated() {
        let r = ActionRepeater()
        #expect(!r.active)
    }

    @Test func activeAfterStart() {
        let r = ActionRepeater()
        r.start(interval: 1.0) { /* noop */ }
        #expect(r.active)
        r.stop()
        #expect(!r.active)
    }

    @Test func stopIsIdempotent() {
        let r = ActionRepeater()
        r.stop()
        r.stop()
        #expect(!r.active)
    }

    @Test func startWhileActiveIsNoOp() {
        let r = ActionRepeater()
        r.start(interval: 1.0) { /* noop */ }
        r.start(interval: 1.0) { /* second appel ignoré */ }
        #expect(r.active)
        r.stop()
    }

    @MainActor
    @Test func firesClosureRepeatedly() async throws {
        let counter = Counter()
        let r = ActionRepeater()
        r.start(interval: 0.05) { counter.increment() }
        // Laisse passer ~ 4 ticks (200ms à 50ms d'intervalle)
        try await Task.sleep(nanoseconds: 220_000_000)
        r.stop()
        #expect(counter.value >= 3, "au moins 3 ticks attendus, observé \(counter.value)")
    }

    @MainActor
    @Test func doesNotFireAfterStop() async throws {
        let counter = Counter()
        let r = ActionRepeater()
        r.start(interval: 0.05) { counter.increment() }
        try await Task.sleep(nanoseconds: 70_000_000)
        r.stop()
        let snapshot = counter.value
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(counter.value == snapshot, "le timer doit s'arrêter après stop()")
    }
}

/// Compteur minimal pour les tests async (évite l'usage d'`actor` qui complique
/// les closures non-isolées passées au `Timer`).
private final class Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

@Suite("tryCatch — capture des erreurs sans propagation")
struct TryCatchTests {

    @Test func returnsValueOnSuccess() {
        var msg: String? = nil
        let result = tryCatch(into: &msg) { return 42 }
        #expect(result == 42)
        #expect(msg == nil)
    }

    @Test func capturesChaqaqErrorAsUserMessage() {
        var msg: String? = nil
        let result: Int? = tryCatch(into: &msg) {
            throw ChaqaqError.NotFound(id: "abc")
        }
        #expect(result == nil)
        #expect(msg?.contains("introuvable") == true)
    }

    @Test func capturesGenericErrorAsLocalizedDescription() {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "ça a explosé" }
        }
        var msg: String? = nil
        let result: Int? = tryCatch(into: &msg) { throw Boom() }
        #expect(result == nil)
        #expect(msg == "ça a explosé")
    }
}
