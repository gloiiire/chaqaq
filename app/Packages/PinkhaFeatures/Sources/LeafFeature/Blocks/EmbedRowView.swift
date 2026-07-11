import SwiftUI
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
            if let parsed = URL(string: url) {
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

    /// Google's free `s2/favicons` service hosts a 32 px PNG for
    /// every public host — used to render a little site identifier
    /// next to the URL's hostname in the embed card's footer.
    private var faviconURL: URL? {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        return URL(string:
            "https://www.google.com/s2/favicons?sz=64&domain=\(host)")
    }

    private var prettyHost: String {
        URL(string: url)?.host ?? url
    }

    private func loadIfNeeded() async {
        guard external == nil, let parsed = URL(string: url) else { return }
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
