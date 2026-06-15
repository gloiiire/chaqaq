import Testing
import SwiftUI
import PinkhaFFI
import PinkhaCore
@testable import Pinkha

@Suite("PinkhaError — user messages and recoverability")
struct PinkhaErrorUXTests {

    @Test func notFoundProducesFriendlyMessage() {
        let msg = PinkhaError.NotFound(id: "abc").userMessage
        #expect(msg.contains("could not be found") || msg.contains("deleted"))
    }

    @Test func invalidOperationIncludesDetail() {
        let msg = PinkhaError.InvalidOperation(detail: "UUID invalide").userMessage
        #expect(msg.contains("UUID invalide"))
    }

    @Test func storageMessageIncludesDetail() {
        // Detail is surfaced verbatim so import errors (path issues, etc.)
        // give the user something actionable.
        let msg = PinkhaError.Storage(detail: "textbundle root does not exist: /foo").userMessage
        #expect(msg.contains("textbundle root does not exist"))
    }

    @Test func storageMessageFallsBackWhenDetailIsEmpty() {
        let msg = PinkhaError.Storage(detail: "").userMessage
        #expect(msg.contains("try again") || msg.contains("Try again"))
    }

    @Test func onlyStorageIsRecoverable() {
        #expect(PinkhaError.Storage(detail: "x").isRecoverable)
        #expect(!PinkhaError.NotFound(id: "x").isRecoverable)
        #expect(!PinkhaError.InvalidOperation(detail: "x").isRecoverable)
    }
}

@Suite("ActionRepeater — repeat timer")
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
        r.start(interval: 1.0) { /* second call ignored */ }
        #expect(r.active)
        r.stop()
    }

    @MainActor
    @Test func firesClosureRepeatedly() async throws {
        let counter = Counter()
        let r = ActionRepeater()
        r.start(interval: 0.05) { counter.increment() }
        // Allow ~4 ticks (200ms at 50ms interval)
        try await Task.sleep(nanoseconds: 220_000_000)
        r.stop()
        #expect(counter.value >= 3, "expected at least 3 ticks, observed \(counter.value)")
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
        #expect(counter.value == snapshot, "the timer must stop firing after stop()")
    }
}

/// Minimal counter for async tests (avoids `actor` which complicates
/// non-isolated closures passed to `Timer`).
private final class Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

@Suite("tryCatch — error capture without propagation")
struct TryCatchTests {

    @Test func returnsValueOnSuccess() {
        var msg: String? = nil
        let result = tryCatch(into: &msg) { return 42 }
        #expect(result == 42)
        #expect(msg == nil)
    }

    @Test func capturesPinkhaErrorAsUserMessage() {
        var msg: String? = nil
        let result: Int? = tryCatch(into: &msg) {
            throw PinkhaError.NotFound(id: "abc")
        }
        #expect(result == nil)
        #expect(msg?.contains("could not be found") == true || msg?.contains("deleted") == true)
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
