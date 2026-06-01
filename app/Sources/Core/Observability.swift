import Foundation
import Sentry

/// Thin wrapper around the Sentry SDK. Call `start()` once at app boot, then
/// use `capture(_:)` to record errors. The DSN is read from `Info.plist`
/// (`SENTRY_DSN` key, injected at build time from `app/Config/Secrets.xcconfig`).
enum Observability {

    /// Boots Sentry. No-op when the DSN is missing or still set to the
    /// placeholder — e.g. on a fresh checkout without local secrets.
    static func start() {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String ?? ""
        #if DEBUG
        // Surface what was actually loaded so a missing/malformed DSN is easy
        // to diagnose from the Xcode console.
        print("[Observability] SENTRY_DSN from Info.plist: \(raw.isEmpty ? "(empty)" : raw)")
        #endif
        guard !raw.isEmpty, !raw.contains("your-dsn-here") else {
            #if DEBUG
            print("[Observability] Sentry disabled (no DSN or placeholder).")
            #endif
            return
        }
        SentrySDK.start { options in
            options.dsn = raw
            options.environment = isDebugBuild ? "debug" : "release"
            options.attachStacktrace = true
            // Verbose SDK logs in debug builds — proves the init path ran.
            options.debug = isDebugBuild
            // Distributed tracing: sentry-cocoa swizzles URLSession and injects
            // the `sentry-trace` header on outbound requests, so the proxy can
            // correlate the iOS trace with its own span.
            options.enableAutoPerformanceTracing = true
            // 100% in dev for visibility, reduced in release to control volume.
            options.tracesSampleRate = isDebugBuild ? 1.0 : 0.2
        }
        #if DEBUG
        print("[Observability] Sentry started.")
        #endif
    }

    /// Reports an error to Sentry. Safe to call before `start()`: the SDK
    /// silently no-ops when uninitialized.
    static func capture(_ error: Error) {
        SentrySDK.capture(error: error)
    }

    /// Reports an arbitrary message, useful for unexpected non-error states
    /// worth investigating after the fact.
    static func capture(message: String) {
        SentrySDK.capture(message: message)
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
