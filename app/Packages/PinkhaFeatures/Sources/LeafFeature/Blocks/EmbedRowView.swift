import SwiftUI
import PinkhaCore
import PinkhaDesignSystem

// ── Embed row ────────────────────────────────────────────────────────────────
//
// Rich card preview for a single URL — Notion's "web bookmark" /
// Craft's link cards. Two flavours :
//
//   • `pinkha://leaf/{uuid}` → resolves the target leaf via the
//     `BlockCallbacks.resolveChildLeaf` closure (same path used by the
//     Page-block row) and shows the doc's title + icon instantly.
//   • Any `http(s)://` URL → asynchronously fetches OpenGraph tags
//     via `EmbedMetadataStore`. Falls back to host + URL while
//     loading or when the fetch fails.

public struct EmbedRowView: View {
    let url: String
    let cb: BlockCallbacks
    /// Resolved metadata for the external case — populated once the
    /// OpenGraph fetch finishes. Keeps the body cheap to re-render
    /// (no work in the body itself, just reading the state).
    @State private var external: EmbedMetadata?
    @State private var loadedImage: UIImage?
    @Environment(AppSettings.self) private var settings

    /// Only `http(s)` embeds are ever handed to `UIApplication.open`.
    private var openableURL: URL? { safeExternalEmbedURL(url) }

    public var body: some View {
        Group {
            if let parsed = URL(string: url),
               parsed.scheme == "pinkha", parsed.host == "leaf" {
                internalCard(leafId: String(parsed.path.dropFirst()))
            } else {
                externalCard
            }
        }
        .padding(.vertical, 4)
    }

    // ── Internal pinkha:// ────────────────────────────────────────────────

    @ViewBuilder
    private func internalCard(leafId: String) -> some View {
        let resolved = cb.resolveChildLeaf?(leafId)
        Button {
            cb.onOpenInternalLeaf?(leafId)
        } label: {
            HStack(spacing: 12) {
                Text(resolved?.icon ?? "📄")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(resolved?.title.isEmpty == false
                          ? resolved!.title : "Untitled")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("pinkha leaf")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.tertiary)
                    .font(.subheadline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.pinkhaSurfaceElevated)
            )
        }
        .buttonStyle(.plain)
    }

    // ── External ──────────────────────────────────────────────────────────

    private var externalCard: some View {
        Button {
            if let parsed = openableURL {
                UIApplication.shared.open(parsed)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Cover image — full width on top, sized to a tasteful
                // 16:9 thumbnail. Smooth in once loaded; skeleton
                // placeholder while the OG fetch resolves.
                ZStack {
                    if let image = loadedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color.pinkhaSurfaceNested)
                        if external?.imageURL != nil {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.secondary)
                        }
                    }
                }
                .frame(height: 160)
                .clipped()

                VStack(alignment: .leading, spacing: 4) {
                    Text(external?.title ?? prettyHost)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let description = external?.description,
                       !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 6) {
                        // Favicon — Google's free favicon service hands
                        // back a 32 px PNG keyed on host; instant fall-
                        // back to a globe glyph when network is down.
                        if let favicon = faviconURL {
                            AsyncImage(url: favicon) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFit()
                                default:
                                    Image(systemName: "globe")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "globe")
                                .foregroundStyle(.tertiary)
                        }
                        Text(prettyHost)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.pinkhaSurfaceElevated)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: url) { await loadIfNeeded() }
    }

    /// The site's own `/favicon.ico`, not a favicon *service*.
    ///
    /// This used to hit `google.com/s2/favicons?domain=<host>`, which
    /// meant every bookmark a user saved announced its host to Google —
    /// a third party that has nothing to do with the note, contacted
    /// merely because the note scrolled into view. Fetching from the
    /// origin the user already chose to embed adds no new party.
    /// Hosts without a root favicon just fall through to the globe
    /// glyph, exactly as an unreachable service did.
    private var faviconURL: URL? {
        guard settings.linkPreviewsEnabled,
              let parsed = openableURL,
              var comps = URLComponents(url: parsed, resolvingAgainstBaseURL: false)
        else { return nil }
        comps.path = "/favicon.ico"
        comps.query = nil
        comps.fragment = nil
        return comps.url
    }

    private var prettyHost: String {
        URL(string: url)?.host ?? url
    }

    private func loadIfNeeded() async {
        // Rendering a leaf must not silently phone out when the user
        // has asked it not to.
        guard settings.linkPreviewsEnabled else { return }
        guard external == nil, let parsed = openableURL else { return }
        let metadata = await EmbedMetadataStore.shared.metadata(for: parsed)
        await MainActor.run { self.external = metadata }
        if let imageURL = metadata?.imageURL {
            // Image loading runs after the meta fetch so the card text
            // shows up first — perceived speed.
            if let (data, _) = try? await URLSession.shared.data(from: imageURL),
               let img = UIImage(data: data) {
                await MainActor.run { self.loadedImage = img }
            }
        }
    }
}

/// Narrows an Embed block's stored URL to something safe to open or fetch,
/// returning `nil` when it isn't.
///
/// The URL in an Embed block is not necessarily something the user typed:
/// importers write it straight from the source file, so a crafted Notion
/// export or `.realm` bundle can put any scheme in there. Handing that to
/// `UIApplication.open` would fire an arbitrary system action —
/// `shortcuts://run-shortcut?name=…`, `facetime://`, a `mailto:` compose —
/// from a card that renders as an ordinary bookmark.
///
/// Free function rather than a `View` member so it is directly testable.
func safeExternalEmbedURL(_ raw: String) -> URL? {
    guard let parsed = URL(string: raw),
          let scheme = parsed.scheme?.lowercased(),
          scheme == "https" || scheme == "http",
          parsed.host?.isEmpty == false
    else { return nil }
    return parsed
}
