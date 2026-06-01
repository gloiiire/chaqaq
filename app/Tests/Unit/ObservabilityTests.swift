import Testing
@testable import Pinkha

// `Observability` is a thin wrapper around Sentry. We can't reach into the
// SDK's internal state from tests, but we can pin down its public contract:
// the wrapper must tolerate misconfiguration without crashing the host app.

@Suite("Observability wrapper")
struct ObservabilityTests {

    @Test("start() is safe to invoke when Sentry is not configured")
    func startIsSafeWithoutDsn() {
        // The test bundle has no SENTRY_DSN in Info.plist, so start() should
        // detect the missing key and silently no-op. The contract: no crash,
        // no exception, just a benign return.
        Observability.start()
    }

    @Test("capture(_:) tolerates calls before start()")
    func captureBeforeStartIsSafe() {
        // The wrapper documents that capture is safe to call before start().
        // We rely on the SDK's own no-op behaviour when uninitialized — the
        // wrapper must not add a precondition that breaks this guarantee.
        struct DummyError: Error {}
        Observability.capture(DummyError())
    }

    @Test("capture(message:) tolerates calls before start()")
    func captureMessageBeforeStartIsSafe() {
        Observability.capture(message: "test message")
    }
}
