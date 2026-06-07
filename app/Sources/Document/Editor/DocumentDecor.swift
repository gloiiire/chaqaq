import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Displays the document cover and emoji icon, with associated action menus.
struct DocumentDecorView: View {
    let cover: String?
    let icone: String?
    let recentEmojis: [String]
    let verrouille: Bool
    let onCouverture: (String?) -> Void
    let onImageData: (Data) -> Void
    let onImageFichier: (URL) -> Void
    let onIcone: (String?) -> Void
    @State private var photoSelection: PhotosPickerItem?
    @State private var photosPickerOuvert = false
    @State private var fichierOuvert = false
    @State private var emojiPickerOuvert = false

    // UIMenu does not scroll: the inline menu only shows recents.
    // "All emojis" opens the full sheet.
    private let covers: [(String, String)] = [
        ("cover.nebula", "Nebula"), ("cover.aurora", "Aurora"),
        ("cover.forest", "Forest"), ("cover.sunset", "Sunset"), ("cover.ocean", "Ocean")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let coverId = cover {
                coverView(coverId)
                    .containerRelativeFrame(.horizontal)
                    .frame(height: 220)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        iconeBouton
                            .padding(.leading, 24)
                            .offset(y: 42)
                    }
            } else if icone != nil {
                iconeBouton
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }

            if !verrouille {
                HStack(spacing: 10) {
                    coverMenu
                    iconMenu
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, cover == nil && icone == nil ? 12 : 50)
            } else if cover != nil {
                Color.clear.frame(height: 50)
            }
        }
        .containerRelativeFrame(.horizontal, alignment: .leading)
        .photosPicker(isPresented: $photosPickerOuvert, selection: $photoSelection, matching: .images)
        .fileImporter(isPresented: $fichierOuvert, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                onImageFichier(url)
            }
        }
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        onImageData(data)
                        photoSelection = nil
                    }
                }
            }
        }
        .sheet(isPresented: $emojiPickerOuvert) {
            EmojiPickerSheet(selection: icone, recents: recentEmojis) { emoji in
                onIcone(emoji)
            }
        }
    }

    private var iconeBouton: some View {
        Menu {
            iconMenuContenu
        } label: {
            Text(icone ?? "📝")
                .font(.system(size: 58))
                .frame(width: 76, height: 76)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(verrouille)
    }

    private var coverMenu: some View {
        Menu {
            coverMenuContenu
        } label: {
            Label(cover == nil ? "Add cover" : "Change cover", systemImage: "photo")
        }
    }

    private var iconMenu: some View {
        Menu {
            iconMenuContenu
        } label: {
            Label(icone == nil ? "Add icon" : "Change icon", systemImage: "face.smiling")
        }
    }

    @ViewBuilder
    private var coverMenuContenu: some View {
        Button {
            photosPickerOuvert = true
        } label: {
            Label("Choose from Photos", systemImage: "photo.on.rectangle")
        }
        Button {
            fichierOuvert = true
        } label: {
            Label("Choose a file", systemImage: "folder")
        }
        Divider()
        ForEach(covers, id: \.0) { id, nom in
            Button(nom) { onCouverture(id) }
        }
        if cover != nil {
            Divider()
            Button(role: .destructive) { onCouverture(nil) } label: {
                Label("Remove cover", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var iconMenuContenu: some View {
        Button {
            emojiPickerOuvert = true
        } label: {
            Label("All emojis", systemImage: "face.smiling")
        }
        .tint(.primary)
        if !recentEmojis.isEmpty {
            Divider()
            ForEach(recentEmojis.prefix(8), id: \.self) { emoji in
                Button(emoji) { onIcone(emoji) }
            }
        }
        if icone != nil {
            Divider()
            Button(role: .destructive) { onIcone(nil) } label: {
                Label("Remove icon", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func coverView(_ id: String) -> some View {
        if let image = coverImage(id) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipped()
        } else if id.hasPrefix("http://") || id.hasPrefix("https://"),
                  let url = URL(string: id) {
            // Remote cover (typical case: Notion imports preserve the original
            // cover URL — Notion-hosted URLs expire after ~1h so a future
            // PR should download them locally at import time; for now we
            // resolve them on display).
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    Color.secondary.opacity(0.1)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .clipped()
                case .failure:
                    // URL is dead (expired Notion-hosted file, network
                    // error, etc.) — show the same default gradient as
                    // when no cover is set, so the doc stays usable.
                    Color.secondary.opacity(0.15)
                @unknown default:
                    Color.secondary.opacity(0.1)
                }
            }
        } else {
            switch id {
            case "cover.aurora":
                LinearGradient(colors: [.green, .cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            case "cover.forest":
                LinearGradient(colors: [Color(red: 0.05, green: 0.20, blue: 0.14), .green, Color(red: 0.70, green: 0.84, blue: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case "cover.sunset":
                LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            case "cover.ocean":
                LinearGradient(colors: [.blue, .cyan, Color(red: 0.05, green: 0.08, blue: 0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
            default:
                ZStack {
                    LinearGradient(colors: [Color(red: 0.02, green: 0.02, blue: 0.09), Color(red: 0.16, green: 0.25, blue: 0.55), Color(red: 0.95, green: 0.58, blue: 0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Canvas { context, size in
                        for i in 0..<48 {
                            let x = CGFloat((i * 53) % 997) / 997 * size.width
                            let y = CGFloat((i * 97) % 571) / 571 * size.height
                            let d = CGFloat((i % 3) + 1)
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)), with: .color(.white.opacity(i % 5 == 0 ? 0.95 : 0.55)))
                        }
                    }
                }
            }
        }
    }

    /// Loads a cover from the covers directory (file name) or from a file URL.
    private func coverImage(_ id: String) -> UIImage? {
        if !id.hasPrefix("file://") && !id.hasPrefix("cover.") {
            guard let directory = try? DocumentViewModel.coversDirectory() else { return nil }
            return UIImage(contentsOfFile: directory.appendingPathComponent(id).path)
        }
        guard let url = URL(string: id), url.isFileURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
