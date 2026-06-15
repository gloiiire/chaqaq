import SwiftUI
import PhotosUI

/// Doc-like header for a Database : cover banner (optional) + icon
/// (optional) + large editable title + rich-text description. Mirrors
/// the visual treatment of `DocumentDecorView` so a database opens
/// with the same hero it would have as a Notion page. All edits route
/// through the view model — no direct FFI call inside the view.
struct DatabaseHeaderView: View {
    @Bindable var vm: DatabaseViewModel
    let recentEmojis: [String]

    @State private var photoSelection: PhotosPickerItem?
    @State private var photosPickerOpen = false
    @State private var filePickerOpen = false
    @State private var emojiPickerOpen = false
    @State private var titleDraft = ""
    @State private var descriptionDraft = ""
    @FocusState private var titleFocused: Bool
    @FocusState private var descriptionFocused: Bool

    // Built-in cover gradients shared with documents — keeps the
    // visual vocabulary identical between docs and DBs.
    private let covers: [(String, String)] = [
        ("cover.nebula", "Nebula"),
        ("cover.aurora", "Aurora"),
        ("cover.forest", "Forest"),
        ("cover.sunset", "Sunset"),
        ("cover.ocean",  "Ocean"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let coverId = vm.cover {
                coverBanner(coverId)
                    // `containerRelativeFrame(.horizontal)` makes the
                    // banner ignore parent padding and bleed edge-to-
                    // edge, matching the document cover behaviour.
                    .containerRelativeFrame(.horizontal)
                    .frame(height: 220)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        iconButton
                            .padding(.leading, 24)
                            .offset(y: 42)
                    }
            } else if vm.icon != nil {
                iconButton
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }

            if !vm.locked {
                HStack(spacing: 10) {
                    coverMenu
                    iconMenu
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, vm.cover == nil && vm.icon == nil ? 12 : 50)
            } else if vm.cover != nil {
                // Reserve the same vertical slot when locked so the
                // title doesn't slide upward — matches the document
                // header treatment.
                Color.clear.frame(height: 50)
            }

            // Title + description. Locked databases render plain Text —
            // not a disabled TextField — mirroring how documents swap
            // their editor surfaces out entirely. `.disabled` alone
            // proved bypassable on device (iOS 26 quirk with
            // `axis: .vertical` fields), and a read-only header also
            // shouldn't show the "Add a description" placeholder.
            if vm.locked {
                Text(vm.titlePlain.isEmpty ? String(localized: "Untitled") : vm.titlePlain)
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                if !vm.descriptionPlain.isEmpty {
                    Text(vm.descriptionPlain)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }
            } else {
                // Title — large, freely-editable, syncs to VM on blur.
                TextField("Untitled", text: $titleDraft, axis: .vertical)
                    .font(.system(size: 34, weight: .bold))
                    .focused($titleFocused)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .onAppear { titleDraft = vm.titlePlain }
                    .onChange(of: vm.titlePlain) { _, v in
                        if !titleFocused { titleDraft = v }
                    }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused, titleDraft != vm.titlePlain {
                            vm.saveTitle(titleDraft)
                        }
                    }

                // Description — multiline plain text, lighter weight. Empty
                // is a valid state ; SwiftUI's `TextField` placeholder shows
                // "Add a description" until the user types.
                TextField("Add a description", text: $descriptionDraft, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .focused($descriptionFocused)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .onAppear { descriptionDraft = vm.descriptionPlain }
                    .onChange(of: vm.descriptionPlain) { _, v in
                        if !descriptionFocused { descriptionDraft = v }
                    }
                    .onChange(of: descriptionFocused) { _, focused in
                        if !focused, descriptionDraft != vm.descriptionPlain {
                            vm.saveDescription(descriptionDraft)
                        }
                    }
            }
        }
        .photosPicker(isPresented: $photosPickerOpen, selection: $photoSelection, matching: .images)
        .fileImporter(isPresented: $filePickerOpen, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                vm.saveCoverFromFile(url)
            }
        }
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        vm.saveCoverFromData(data)
                        photoSelection = nil
                    }
                }
            }
        }
        .sheet(isPresented: $emojiPickerOpen) {
            EmojiPickerSheet(selection: vm.icon, recents: recentEmojis) { emoji in
                vm.saveIcon(emoji)
            }
        }
    }

    private var iconButton: some View {
        Menu {
            iconMenuContent
        } label: {
            Text(vm.icon ?? "🗂️")
                .font(.system(size: 58))
                .frame(width: 76, height: 76)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(vm.locked)
    }

    private var coverMenu: some View {
        Menu {
            coverMenuContent
        } label: {
            Label(vm.cover == nil ? "Add cover" : "Change cover", systemImage: "photo")
        }
    }

    private var iconMenu: some View {
        Menu {
            iconMenuContent
        } label: {
            Label(vm.icon == nil ? "Add icon" : "Change icon", systemImage: "face.smiling")
        }
    }

    @ViewBuilder
    private var coverMenuContent: some View {
        Button { photosPickerOpen = true } label: {
            Label("Choose from Photos", systemImage: "photo.on.rectangle")
        }
        Button { filePickerOpen = true } label: {
            Label("Choose a file", systemImage: "folder")
        }
        Divider()
        ForEach(covers, id: \.0) { id, name in
            Button(name) { vm.saveCover(id) }
        }
        if vm.cover != nil {
            Divider()
            Button(role: .destructive) { vm.saveCover(nil) } label: {
                Label("Remove cover", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var iconMenuContent: some View {
        Button { emojiPickerOpen = true } label: {
            Label("All emojis", systemImage: "face.smiling")
        }
        .tint(.primary)
        if !recentEmojis.isEmpty {
            Divider()
            ForEach(recentEmojis.prefix(8), id: \.self) { emoji in
                Button(emoji) { vm.saveIcon(emoji) }
            }
        }
        if vm.icon != nil {
            Divider()
            Button(role: .destructive) { vm.saveIcon(nil) } label: {
                Label("Remove icon", systemImage: "trash")
            }
        }
    }

    // ── Cover rendering ──────────────────────────────────────────────────────

    @ViewBuilder
    private func coverBanner(_ id: String) -> some View {
        if id.hasPrefix("http://") || id.hasPrefix("https://"),
           let url = URL(string: id) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill().clipped()
                case .empty, .failure:
                    Color.secondary.opacity(0.1)
                @unknown default:
                    Color.secondary.opacity(0.1)
                }
            }
        } else if id.hasPrefix("cover.") {
            coverGradient(id)
        } else {
            // Local file in the covers directory (reuse the document
            // covers directory — they share storage).
            if let dir = try? DocumentViewModel.coversDirectory(),
               let image = UIImage(contentsOfFile: dir.appendingPathComponent(id).path) {
                Image(uiImage: image).resizable().scaledToFill().clipped()
            } else {
                Color.secondary.opacity(0.1)
            }
        }
    }

    @ViewBuilder
    private func coverGradient(_ id: String) -> some View {
        switch id {
        case "cover.aurora":
            LinearGradient(
                colors: [.green, .cyan, .purple],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "cover.forest":
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.20, blue: 0.14),
                    .green,
                    Color(red: 0.70, green: 0.84, blue: 0.55),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "cover.sunset":
            LinearGradient(
                colors: [.orange, .pink, .purple],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "cover.ocean":
            LinearGradient(
                colors: [.blue, .cyan, Color(red: 0.05, green: 0.08, blue: 0.25)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.02, blue: 0.09),
                    Color(red: 0.16, green: 0.25, blue: 0.55),
                    Color(red: 0.95, green: 0.58, blue: 0.28),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
