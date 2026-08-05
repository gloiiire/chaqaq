import Testing
import Foundation
@testable import LeafFeature
@testable import PinkhaCore

// ── Embed URL guard ───────────────────────────────────────────────────────────
//
// An Embed block's URL can arrive from an importer rather than from the
// user's keyboard, so it is untrusted input that renders as a friendly
// bookmark card.

@Suite("Embed URL guard")
struct EmbedURLGuardTests {

    @Test("accepts ordinary web URLs")
    func acceptsWebURLs() {
        #expect(safeExternalEmbedURL("https://example.com/a") != nil)
        #expect(safeExternalEmbedURL("http://example.com") != nil)
        // Scheme comparison is case-insensitive, as URL parsing is.
        #expect(safeExternalEmbedURL("HTTPS://example.com") != nil)
    }

    @Test("rejects schemes that trigger a system action on tap")
    func rejectsActionSchemes() {
        let hostile = [
            "shortcuts://run-shortcut?name=Wipe",
            "facetime://+15551234567",
            "mailto:someone@example.com",
            "tel:+15551234567",
            "file:///etc/passwd",
            "javascript:alert(1)",
        ]
        for raw in hostile {
            #expect(safeExternalEmbedURL(raw) == nil, "accepted \(raw)")
        }
    }

    @Test("rejects web URLs with no host")
    func rejectsHostlessURLs() {
        // `https:///path` parses, but there is nothing to connect to — and
        // a hostless URL would produce a nonsense favicon request.
        #expect(safeExternalEmbedURL("https:///path") == nil)
        #expect(safeExternalEmbedURL("") == nil)
    }

    @Test("pinkha:// internal links are not openable externally")
    func rejectsInternalScheme() {
        // These are handled by the internal-card branch instead; if one ever
        // reaches the external branch it must not be handed to the system.
        #expect(safeExternalEmbedURL("pinkha://leaf/1234") == nil)
    }
}

// ── Crash-report scrubbing ────────────────────────────────────────────────────

@Suite("Observability path redaction")
struct ObservabilityRedactionTests {

    @Test("strips container paths from error text")
    func stripsPaths() {
        let raw = "Io error: /var/mobile/Containers/Data/Application/ABC-123/Documents/pinkha.db not found"
        let scrubbed = Observability.redactPaths(raw)
        #expect(!scrubbed.contains("/var/mobile"))
        #expect(!scrubbed.contains("ABC-123"))
        // The diagnostic shape survives — that is the point of scrubbing
        // rather than dropping the event.
        #expect(scrubbed.contains("Io error:"))
        #expect(scrubbed.contains("not found"))
    }

    @Test("strips user-chosen import filenames")
    func stripsFilenames() {
        // The exact leak this exists for: an import failure names the file
        // the user picked, and note titles are what people name files.
        let raw = "failed to open /private/var/tmp/Therapy-notes-2026.textbundle"
        let scrubbed = Observability.redactPaths(raw)
        #expect(!scrubbed.contains("Therapy"))
    }

    @Test("leaves path-free messages untouched")
    func leavesCleanTextAlone() {
        let raw = "Storage error: database is locked"
        #expect(Observability.redactPaths(raw) == raw)
    }
}
