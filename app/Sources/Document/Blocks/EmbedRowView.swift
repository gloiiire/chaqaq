import SwiftUI

// ── Embed row ────────────────────────────────────────────────────────────────
//
// Rich card preview for a single URL — Notion's "web bookmark" /
// Craft's link cards. Two flavours :
//
//   • `pinkha://doc/{uuid}` → resolves the target document via the
//     `BlockCallbacks.resolveChildPage` closure (same path used by the
//     Page-block row) and shows the doc's title + icon instantly.
//   • Any `http(s)://` URL → asynchronously fetches OpenGraph tags
//     via `EmbedMetadataStore`. Falls back to host + URL while
//     loading or when the fetch fails.

struct EmbedRowView: View {
    let url: String
    let cb: BlockCallbacks
    /// Resolved metadata for the external case — populated once the
    /// OpenGraph fetch finishes. Keeps the body cheap to re-render
    /// (no work in the body itself, just reading the state).
    @State private var external: EmbedMetadata?
    @State private var loadedImage: UIImage?

    var body: some View {
        Group {
            if let parsed = URL(string: url),
               parsed.scheme == "pinkha", parsed.host == "doc" {
                internalCard(docId: String(parsed.path.dropFirst()))
            } else {
                externalCard
            }
        }
        .padding(.vertical, 4)
    }

    // ── Internal pinkha:// ────────────────────────────────────────────────

    @ViewBuilder
    private func internalCard(docId: String) -> some View {
        let resolved = cb.resolveChildPage?(docId)
        Button {
            cb.onOpenInternalDoc?(docId)
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
                    Text("pinkha note")
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
                    .fill(Color(uiColor: .secondarySystemBackground))
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
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(external?.title ?? prettyHost)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let description = external?.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(prettyHost)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let image = loadedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if external?.imageURL != nil {
                    // Image URL known but not loaded yet — placeholder.
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemBackground))
                        .frame(width: 64, height: 64)
                        .overlay {
                            ProgressView()
                        }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .task(id: url) { await loadIfNeeded() }
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
