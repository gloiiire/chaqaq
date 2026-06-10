import Foundation
import UIKit

// ── Embed metadata ────────────────────────────────────────────────────────────
//
// Lazy fetcher + in-memory cache for OpenGraph / Twitter-card metadata
// behind a URL. Used by `EmbedRowView` to render a rich card preview for
// external bookmarks. The fetch is bounded (1 s timeout, 256 KB body
// cap) so a slow or absurdly large host can't block the editor — the
// card just falls back to its host + URL placeholder.

/// Pre-resolved bundle for one URL : title, optional description,
/// optional cover image URL. Empty values are tolerated and rendered
/// as "missing" in the UI (we show the host instead of the title for
/// instance).
struct EmbedMetadata: Equatable {
    var title: String
    var description: String?
    var imageURL: URL?
    /// Convenience : the host of the original URL. Computed by the
    /// fetcher so the row doesn't have to reparse the URL.
    var host: String
}

/// Process-wide cache + fetcher. Lives behind an actor so multiple
/// `EmbedRowView`s pointing at the same URL share one in-flight
/// request and one result. Cleared automatically on memory warning.
actor EmbedMetadataStore {
    static let shared = EmbedMetadataStore()

    private var cache: [URL: EmbedMetadata] = [:]
    private var inflight: [URL: Task<EmbedMetadata?, Never>] = [:]

    init() {
        // Drop the cache on memory warnings so a long editing session
        // doesn't accumulate unbounded HTML payloads.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil,
        ) { _ in
            Task { await EmbedMetadataStore.shared.purge() }
        }
    }

    /// Returns metadata for `url`, fetching it on first call and
    /// reusing the cached value thereafter. `nil` means fetch failed
    /// — callers should fall back to host + URL display.
    func metadata(for url: URL) async -> EmbedMetadata? {
        if let cached = cache[url] { return cached }
        if let task = inflight[url] { return await task.value }
        let task = Task<EmbedMetadata?, Never> { [url] in
            await Self.fetch(url: url)
        }
        inflight[url] = task
        let result = await task.value
        inflight[url] = nil
        if let result { cache[url] = result }
        return result
    }

    func purge() { cache.removeAll() }

    /// One-shot HTTP GET → HTML → OG tag scrape. Bounded request so a
    /// slow or huge server can't hang the editor.
    private static func fetch(url: URL) async -> EmbedMetadata? {
        let host = url.host ?? ""
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        request.setValue(
            // Identify as a regular browser — some sites refuse non-
            // browser UAs and skip the OG tags they normally serve.
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent",
        )
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return EmbedMetadata(title: host, description: nil,
                                 imageURL: nil, host: host)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let raw = String(data: data.prefix(256 * 1024), encoding: .utf8)
                ?? String(data: data.prefix(256 * 1024), encoding: .isoLatin1)
        else {
            return EmbedMetadata(title: host, description: nil,
                                 imageURL: nil, host: host)
        }
        let title = scrape(raw, properties: ["og:title", "twitter:title"])
            ?? scrapeTitleTag(raw)
            ?? host
        let description = scrape(raw, properties: ["og:description", "twitter:description", "description"])
        let imageURLString = scrape(raw, properties: ["og:image", "twitter:image"])
        let imageURL = imageURLString.flatMap { resolveImageURL($0, base: url) }
        return EmbedMetadata(
            title: title,
            description: description,
            imageURL: imageURL,
            host: host,
        )
    }

    /// Walks the HTML head looking for an OpenGraph / Twitter / classic
    /// meta tag with one of the requested property names. Returns the
    /// `content="…"` value of the first match.
    private static func scrape(_ html: String, properties: [String]) -> String? {
        // `<meta property="og:title" content="…">` — also matches
        // `name="…"` for Twitter / classic descriptions. We don't
        // build a full DOM; the regex is good enough for the meta
        // section, which is invariably at the top of the document.
        for prop in properties {
            let pattern = #"<meta[^>]+(?:property|name)\s*=\s*['\"]"# + prop
                + #"['\"][^>]+content\s*=\s*['\"]([^'\"]+)['\"]"#
            if let value = firstMatch(in: html, pattern: pattern) {
                return decodeEntities(value)
            }
            let pattern2 = #"<meta[^>]+content\s*=\s*['\"]([^'\"]+)['\"][^>]+(?:property|name)\s*=\s*['\"]"# + prop + #"['\"]"#
            if let value = firstMatch(in: html, pattern: pattern2) {
                return decodeEntities(value)
            }
        }
        return nil
    }

    /// Fallback : extracts the `<title>` tag content for sites that
    /// don't expose OpenGraph tags.
    private static func scrapeTitleTag(_ html: String) -> String? {
        firstMatch(in: html, pattern: #"<title[^>]*>([^<]+)</title>"#)
            .map { decodeEntities($0) }
    }

    private static func firstMatch(in html: String, pattern: String) -> String? {
        let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators],
        )
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex?.firstMatch(in: html, range: range),
              match.numberOfRanges >= 2,
              let group = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[group])
    }

    /// Best-effort HTML entity decoder — covers the handful that show
    /// up in OG titles : `&amp; &lt; &gt; &quot; &#39; &nbsp;` etc.
    /// `NSAttributedString(data:options:.html)` would be more complete
    /// but blocks the main thread and is overkill for a meta value.
    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let pairs: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
            ("&nbsp;", " "), ("&hellip;", "…"),
        ]
        for (from, to) in pairs {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolves a relative image URL (`/img.png`) against the page's
    /// base URL so the card can load the asset.
    private static func resolveImageURL(_ raw: String, base: URL) -> URL? {
        if let absolute = URL(string: raw), absolute.scheme != nil {
            return absolute
        }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }
}
