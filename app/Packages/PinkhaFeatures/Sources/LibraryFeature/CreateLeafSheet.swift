import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PinkhaFFI
import PinkhaCore
import PinkhaDesignSystem
import PinkhaComposer
import LeafFeature

/// Sheet for creating a new leaf or book. Accepts a title and calls `onCreate` or `onCancel`.
///
/// `prompt` and `navigationTitle` are `LocalizedStringKey` (not `String`)
/// so the catalog resolves them — `TextField(_ titleKey:)` and
/// `navigationTitle(_:)` both pick the localized overload only when the
/// argument type is a key. With raw `String` SwiftUI displays the
/// English source verbatim.
///
/// When `availableBooks` is non-empty and `api` is set, a "Add to
/// a book" toggle reveals a DB picker + an inline property editor.
/// `onCreate` then carries `(bookId, propertyValues)` so the
/// caller can route the create to either the regular leaves path or a
/// DB-entry creation path.
public struct CreateLeafSheet: View {
    public init(
        title: Binding<String>,
        prompt: LocalizedStringKey = "Leaf title",
        navigationTitle: LocalizedStringKey = "New",
        availableBooks: [BookMetaFfi] = [],
        api: PinkhaApi? = nil,
        onCreate: @escaping (String?, [String: PropertyValueFfi], StandaloneStyle) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._title = title
        self.prompt = prompt
        self.navigationTitle = navigationTitle
        self.availableBooks = availableBooks
        self.api = api
        self.onCreate = onCreate
        self.onCancel = onCancel
    }
    @Binding public var title: String
    public var prompt: LocalizedStringKey = "Leaf title"
    /// Navigation title — defaults to "New" but each call site sets a
    /// more descriptive label (e.g. "New Leaf", "New Book") so the
    /// user knows what they're creating before they type.
    public var navigationTitle: LocalizedStringKey = "New"
    /// Available books the user can attach the leaf to. Pass an
    /// empty array to hide the "Add to a book" toggle entirely
    /// (e.g. for the "New book" flow).
    public var availableBooks: [BookMetaFfi] = []
    /// Used to fetch the picked book's schema so we know which
    /// properties to render. `nil` disables the DB-attach flow.
    public var api: PinkhaApi? = nil
    /// `nil` cover / icon / theme = inherit defaults. Only set when
    /// the user explicitly picked something in the style section.
    public let onCreate: (
        _ bookId: String?,
        _ propertyValues: [String: PropertyValueFfi],
        _ standalone: StandaloneStyle
    ) -> Void
    public let onCancel: () -> Void

    @FocusState private var focused: Bool
    @State private var attachToBook: Bool = false
    @State private var pickedBookId: String? = nil
    @State private var pickedBook: BookFfi? = nil
    @State private var pickedBookLoading: Bool = false
    @State private var propertyValues: [String: PropertyValueFfi] = [:]
    @State private var standaloneStyle: StandaloneStyle = .init()
    @State private var showingEmojiPicker = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(prompt, text: $title)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit {
                            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            Haptic.success()
                            commit()
                        }
                }

                // Leaf-style section — always visible when the
                // doc-creation FFI is wired. Cover / icon / theme
                // live on the Leaf itself ; they're orthogonal
                // to the DB membership so we keep them around even
                // when the toggle below files the leaf as a DB row.
                if api != nil {
                    Section("Style") {
                        coverPicker
                        iconPicker
                        themePicker
                        publishDatePicker
                    }
                }

                if api != nil && !availableBooks.isEmpty {
                    Section {
                        Toggle("Add to a book", isOn: $attachToBook)
                            .onChange(of: attachToBook) { _, isOn in
                                Haptic.toggle()
                                if !isOn {
                                    pickedBookId = nil
                                    pickedBook = nil
                                    propertyValues = [:]
                                }
                            }
                    } footer: {
                        Text("Off (default): creates a stand-alone leaf. On: file the leaf as a row of an existing book — pick which one and fill the columns inline.")
                    }

                    if attachToBook {
                        Section("Book") {
                            Picker("Book", selection: Binding(
                                get: { pickedBookId },
                                set: { newId in
                                    pickedBookId = newId
                                    Haptic.tap()
                                    loadBookSchema()
                                }
                            )) {
                                Text("Choose…").tag(String?.none)
                                ForEach(availableBooks, id: \.id) { db in
                                    Text(db.titlePlain.isEmpty ? "Untitled" : db.titlePlain)
                                        .tag(Optional(db.id))
                                }
                            }
                        }

                        if pickedBookLoading {
                            Section { ProgressView().frame(maxWidth: .infinity) }
                        } else if let db = pickedBook {
                            Section("Properties") {
                                ForEach(editableProperties(of: db)) { prop in
                                    PropertyInputRow(
                                        property: prop,
                                        value: Binding(
                                            get: { propertyValues[prop.id] ?? .empty },
                                            set: { propertyValues[prop.id] = $0 }
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onCancel) { Image(systemName: "xmark") }
                        // Cross / dismiss icons stay neutral — the
                        // accent is reserved for "selected" / "active"
                        // affordances, not for closing things.
                        .tint(.primary)
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { commit() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("Create")
                        .disabled(!canCommit)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
        .sheet(isPresented: $showingEmojiPicker) {
            EmojiPickerSheet(
                selection: standaloneStyle.icon,
                recents: []
            ) { emoji in
                standaloneStyle.icon = emoji
                Haptic.tap()
            }
        }
    }

    // ── Standalone style pickers ─────────────────────────────────────────

    @ViewBuilder
    private var coverPicker: some View {
        // Same gradient catalogue as LeafDecor / BookHeader
        // so a doc looks identical whether it was picked here or
        // changed later from the editor.
        let covers: [(String, String, [Color])] = [
            ("cover.nebula",  "Nebula",
             [Color(red: 0.02, green: 0.02, blue: 0.09),
              Color(red: 0.16, green: 0.25, blue: 0.55),
              Color(red: 0.95, green: 0.58, blue: 0.28)]),
            ("cover.aurora", "Aurora", [.green, .cyan, .purple]),
            ("cover.forest", "Forest",
             [Color(red: 0.05, green: 0.20, blue: 0.14), .green,
              Color(red: 0.70, green: 0.84, blue: 0.55)]),
            ("cover.sunset", "Sunset", [.orange, .pink, .purple]),
            ("cover.ocean",  "Ocean",
             [.blue, .cyan, Color(red: 0.05, green: 0.08, blue: 0.25)]),
        ]
        VStack(alignment: .leading, spacing: 6) {
            Label("Cover", systemImage: "photo")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    coverSwatch(label: "None", isSelected: standaloneStyle.cover == nil
                                && standaloneStyle.customCoverData == nil) {
                        standaloneStyle.cover = nil
                        standaloneStyle.customCoverData = nil
                    } overlay: {
                        Image(systemName: "slash.circle")
                            .foregroundStyle(.secondary)
                    }
                    // Custom image swatch — placed right after None so
                    // "personal pick" reads as the first concrete
                    // option, before the built-in gradient catalogue.
                    // Tap opens a menu with Photos / Files sources ;
                    // shows the picked thumbnail when bytes are
                    // queued, dashed-border placeholder otherwise.
                    Menu {
                        Button {
                            Haptic.tap()
                            showingPhotoPicker = true
                        } label: {
                            Label("From Photos", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            Haptic.tap()
                            showingFileImporter = true
                        } label: {
                            Label("From Files", systemImage: "shelf")
                        }
                        if standaloneStyle.customCoverData != nil {
                            Divider()
                            Button(role: .destructive) {
                                Haptic.tap()
                                standaloneStyle.customCoverData = nil
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                if let data = standaloneStyle.customCoverData,
                                   let ui = UIImage(data: data) {
                                    Image(uiImage: ui)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 56, height: 36)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                } else {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.secondary.opacity(0.08))
                                        .frame(width: 56, height: 36)
                                        .overlay(
                                            Image(systemName: "photo.badge.plus")
                                                .foregroundStyle(.secondary))
                                }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        standaloneStyle.customCoverData != nil
                                            ? Color.accentColor
                                            : .secondary.opacity(0.3),
                                        style: StrokeStyle(
                                            lineWidth: standaloneStyle.customCoverData != nil ? 2 : 0.8,
                                            dash: standaloneStyle.customCoverData == nil ? [3, 3] : []
                                        )))
                            Text("Custom")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    ForEach(covers, id: \.0) { id, name, colors in
                        coverSwatch(
                            label: LocalizedStringKey(name),
                            isSelected: standaloneStyle.cover == id
                        ) {
                            // Picking a built-in gradient cancels
                            // any pending custom image — only one
                            // of the two can be active.
                            standaloneStyle.cover = id
                            standaloneStyle.customCoverData = nil
                        } overlay: {
                            LinearGradient(
                                colors: colors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .photosPicker(isPresented: $showingPhotoPicker,
                       selection: $photoSelection,
                       matching: .images)
        .fileImporter(isPresented: $showingFileImporter,
                       allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    // Built-in gradient choice resets so the custom
                    // image is the visible selection.
                    standaloneStyle.cover = nil
                    standaloneStyle.customCoverData = data
                    standaloneStyle.customCoverExt =
                        LeafViewModel.imageExtension(url.pathExtension)
                }
            }
        }
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        standaloneStyle.cover = nil
                        standaloneStyle.customCoverData = data
                        // PhotosPicker normalises to JPEG when read
                        // via Data.self — record that so the file is
                        // saved with the matching extension.
                        standaloneStyle.customCoverExt = "jpg"
                        photoSelection = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func coverSwatch<Overlay: View>(
        label: LocalizedStringKey,
        isSelected: Bool,
        onTap: @escaping () -> Void,
        @ViewBuilder overlay: () -> Overlay
    ) -> some View {
        Button {
            Haptic.tap()
            onTap()
        } label: {
            VStack(spacing: 4) {
                overlay()
                    .frame(width: 56, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .secondary.opacity(0.3),
                                          lineWidth: isSelected ? 2 : 0.5))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var iconPicker: some View {
        Button {
            showingEmojiPicker = true
        } label: {
            HStack {
                Label("Icon", systemImage: "face.smiling")
                    .foregroundStyle(.primary)
                Spacer()
                Text(standaloneStyle.icon ?? "Choose…")
                    .font(.title3)
                    .foregroundStyle(standaloneStyle.icon == nil ? .secondary : .primary)
                if standaloneStyle.icon != nil {
                    Button(role: .destructive) {
                        standaloneStyle.icon = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Lets the user pre-pick a publish date at creation time. `nil`
    /// = stick with the SQLite default ("follow `created_at`"); a
    /// non-nil RFC 3339 timestamp is applied via
    /// `update_leaf_published_at` right after the doc lands.
    /// Mirrors the override sheet in the editor's overflow menu so
    /// the UX vocabulary stays consistent.
    @ViewBuilder
    private var publishDatePicker: some View {
        Toggle(isOn: Binding(
            get: { standaloneStyle.publishedAt != nil },
            set: { isOn in
                Haptic.toggle()
                standaloneStyle.publishedAt = isOn
                    ? ISO8601DateFormatter.fullRfc.string(from: Date())
                    : nil
            }
        )) {
            Label("Custom publish date", systemImage: "paperplane")
        }
        if let iso = standaloneStyle.publishedAt,
           let initial = ISO8601DateFormatter.fullRfc.date(from: iso) {
            DatePicker(
                "Publish date",
                selection: Binding(
                    get: { initial },
                    set: { newDate in
                        standaloneStyle.publishedAt =
                            ISO8601DateFormatter.fullRfc.string(from: newDate)
                    }
                ),
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
        }
    }

    @ViewBuilder
    private var themePicker: some View {
        // Same Theme enum vocabulary as the editor — `nil` means
        // "inherit the global setting". The picker renders inline
        // with a checkmark on the active option.
        Picker(selection: Binding(
            get: { standaloneStyle.theme },
            set: { newTheme in
                standaloneStyle.theme = newTheme
                Haptic.tap()
            }
        )) {
            Text("Default").tag(String?.none)
            ForEach(AppSettings.Theme.allCases) { theme in
                Text(theme.label).tag(Optional(theme.rawValue))
            }
        } label: {
            Label("Theme", systemImage: "book.pages")
        }
    }

    private var canCommit: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // When the user opts into a DB destination, they must pick
        // an actual book before we let the submit fire.
        if attachToBook && pickedBookId == nil { return false }
        return true
    }

    private func commit() {
        guard canCommit else { return }
        // Style + DB membership are orthogonal — the doc keeps its
        // chosen cover / icon / theme whether or not it's also
        // filed as a row of a book.
        onCreate(attachToBook ? pickedBookId : nil, propertyValues, standaloneStyle)
    }

    /// Properties of `db` that we want to render in the inline editor.
    /// We hide the system page-link property and the Title column —
    /// Title is filled with the doc title we already collect above.
    private func editableProperties(of db: BookFfi) -> [PropertyFfi] {
        db.properties.filter { prop in
            if prop.name == "__pinkha_page__" { return false }
            if case .title = prop.propertyType { return false }
            return true
        }
    }

    private func loadBookSchema() {
        guard let bookId = pickedBookId,
              let api else {
            pickedBook = nil
            propertyValues = [:]
            return
        }
        pickedBookLoading = true
        Task.detached(priority: .userInitiated) {
            let decoded = try? api.getBook(id: bookId)
            await MainActor.run {
                pickedBook = decoded
                propertyValues = [:]
                pickedBookLoading = false
            }
        }
    }
}
