import SwiftUI
import UIKit
import PinkhaCore

// ── Cover image view ─────────────────────────────────────────────────────────

/// Renders a leaf cover from the value stored on `Leaf.cover` —
/// local filename in the covers directory, `file://` URL, remote
/// `http(s)://` URL, gradient preset (`cover.aurora` / `forest` /
/// `sunset` / `ocean`), or a soft default when the value is empty / nil.
///
/// Shared between the leaf editor's banner and the home view's
/// recent cards so a doc looks the same in both places (Notion-style).
public struct CoverImageView: View {
    public init(cover: String?) { self.cover = cover }
    public let cover: String?

    public var body: some View {
        Group {
            if let id = cover, !id.isEmpty {
                content(for: id)
            } else {
                placeholder
            }
        }
    }

    @ViewBuilder
    private func content(for id: String) -> some View {
        if let image = localImage(id) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if id.hasPrefix("http://") || id.hasPrefix("https://"),
                  let url = URL(string: id) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    Color.secondary.opacity(0.1)
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            switch id {
            case "cover.aurora":
                LinearGradient(colors: [.green, .cyan, .purple],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            case "cover.forest":
                LinearGradient(colors: [Color(red: 0.05, green: 0.20, blue: 0.14), .green,
                                        Color(red: 0.70, green: 0.84, blue: 0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            case "cover.sunset":
                LinearGradient(colors: [.orange, .pink, .purple],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            case "cover.ocean":
                LinearGradient(colors: [.blue, .cyan,
                                        Color(red: 0.05, green: 0.08, blue: 0.25)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            default:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color.secondary.opacity(0.18),
                     Color.secondary.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func localImage(_ id: String) -> UIImage? {
        if !id.hasPrefix("file://") && !id.hasPrefix("cover.") {
            guard let directory = try? CoverImageStorage.directory() else { return nil }
            return UIImage(contentsOfFile: directory.appendingPathComponent(id).path)
        }
        guard let url = URL(string: id), url.isFileURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
