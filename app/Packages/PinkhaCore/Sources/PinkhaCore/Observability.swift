import Foundation
import Sentry

/// Thin wrapper around the Sentry SDK. Call `start()` once at app boot, then
/// use `capture(_:)` to record errors. The DSN is read from `Info.plist`
/// (`SENTRY_DSN` key, injected at build time from `app/Config/Secrets.xcconfig`).
public enum Observability {

    /// Boots Sentry. No-op when the DSN is missing or still set to the
    /// placeholder — e.g. on a fresh checkout without local secrets.
    ///
    /// Also a no-op when running under XCTest. The unit-test target is
    /// hosted by the app, so `Bundle.main` returns the app's Info.plist
    /// (with a real SENTRY_DSN). Without this guard, every test that
    /// throws an error through `tryCatch` / `Observability.capture` would
    /// reach sentry.io for real and pollute the production dashboard.
    public static func start() {
        guard !isRunningUnderXCTest else {
            #if DEBUG
            print("[Observability] Sentry disabled (running under XCTest).")
            #endif
            return
        }
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

            // …but NOT URLSession span capture. Swizzling every request turns
            // the set of links a user pastes into their private notes into
            // Sentry span data: `EmbedRowView` fetches OpenGraph metadata for
            // each embedded URL automatically, so host + path of those links
            // would ship off-device. Query strings are sanitized by the SDK,
            // but host and path are the identifying part.
            //
            // Distributed tracing to notion-proxy is unaffected — the
            // `sentry-trace` header is injected independently of this flag.
            options.enableNetworkTracking = false
            options.enableCaptureFailedRequests = false

            // Scrub note-derived text before anything leaves the device.
            //
            // `tryCatch` forwards every `PinkhaError.Storage` here, and that
            // variant is built from `CoreError::Io` — whose `Display`
            // includes the full path, i.e. the container UUID *and the
            // user-selected import filename*. A file called
            // "Therapy notes 2026.textbundle" became a Sentry event title.
            options.beforeSend = { event in
                // `SentryMessage.formatted` is read-only, so rebuild it.
                if let formatted = event.message?.formatted {
                    event.message = SentryMessage(formatted: redactPaths(formatted))
                }
                event.exceptions?.forEach { exception in
                    exception.value = redactPaths(exception.value)
                }
                return event
            }
        }
        #if DEBUG
        print("[Observability] Sentry started.")
        #endif
    }

    /// Replaces filesystem paths with a placeholder, keeping the error shape
    /// but dropping the container UUID and any user-chosen filename.
    static func redactPaths(_ text: String) -> String {
        guard text.contains("/") else { return text }
        // Any run of non-space characters containing a slash is treated as a
        // path. Coarse on purpose: over-redacting a diagnostic string is
        // cheap, leaking a note title is not.
        return text
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { token in token.contains("/") ? "<path>" : String(token) }
            .joined(separator: " ")
    }

    /// Reports an error to Sentry. Safe to call before `start()`: the SDK
    /// silently no-ops when uninitialized.
    public static func capture(_ error: Error) {
        SentrySDK.capture(error: error)
    }

    /// Records a lightweight breadcrumb that will be attached to the next
    /// captured event. Use this for flow tracing ("step N happened") — it's
    /// cheap (~microseconds, no stacktrace, batched in-memory) and survives
    /// app hangs the same way crash reports do.
    ///
    /// Do NOT use `SentrySDK.capture(message:)` in hot paths: each call
    /// serializes a full Event with a ~30-frame stacktrace and ships it
    /// synchronously, which blocks the main thread for hundreds of
    /// milliseconds and can suspend awaiting Tasks.
    public static func capture(message: String) {
        let breadcrumb = Breadcrumb(level: .info, category: "app")
        breadcrumb.message = message
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    /// Captures a message as a full Sentry event (with stacktrace). Heavy —
    /// only call once per investigation, e.g. at the failure site. For
    /// regular flow tracing, prefer `capture(message:)` which is now a
    /// breadcrumb.
    public static func captureAsEvent(message: String) {
        SentrySDK.capture(message: message)
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// `true` when the current process is running an XCTest bundle.
    /// XCTest sets this env var to the absolute path of the test config
    /// plist before launching the runner — present in both unit and UI
    /// test contexts.
    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
