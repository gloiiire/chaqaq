import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// ── Shared components ─────────────────────────────────────────────────────────

/// Section header in uppercase with semi-bold caption style.
///
/// `title` is a `LocalizedStringKey` so the string is resolved via
/// `Localizable.xcstrings` (instead of `String`, which SwiftUI treats
/// as a literal and never localizes). The visual uppercase comes from
/// `.textCase(.uppercase)` — applying `.uppercased()` to the raw String
/// would bypass the catalog lookup.
struct SectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
            .textCase(.uppercase)
    }
}

/// Greeting displayed at the top of the Notes tab.
struct GreetingHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.largeTitle.bold())
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Placeholder shown when there are no documents yet.
struct NotesEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("No notes").font(.headline)
                Text("Tap the button at the bottom right\nto create your first note.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Sheet for creating a new note or database. Accepts a title and calls `onCreate` or `onCancel`.
///
/// `prompt` and `navigationTitle` are `LocalizedStringKey` (not `String`)
/// so the catalog resolves them — `TextField(_ titleKey:)` and
/// `navigationTitle(_:)` both pick the localized overload only when the
/// argument type is a key. With raw `String` SwiftUI displays the
/// English source verbatim.
///
/// When `availableDatabases` is non-empty and `api` is set, a "Add to
/// a database" toggle reveals a DB picker + an inline property editor.
/// `onCreate` then carries `(databaseId, propertyValues)` so the
/// caller can route the create to either the regular notes path or a
/// DB-entry creation path.
struct CreateDocumentSheet: View {
    @Binding var title: String
    var prompt: LocalizedStringKey = "Document title"
    /// Navigation title — defaults to "New" but each call site sets a
    /// more descriptive label (e.g. "New Document", "New Database") so the
    /// user knows what they're creating before they type.
    var navigationTitle: LocalizedStringKey = "New"
    /// Available databases the user can attach the note to. Pass an
    /// empty array to hide the "Add to a database" toggle entirely
    /// (e.g. for the "New database" flow).
    var availableDatabases: [DatabaseMetaFfi] = []
    /// Used to fetch the picked database's schema so we know which
    /// properties to render. `nil` disables the DB-attach flow.
    var api: PinkhaApi? = nil
    /// `nil` cover / icon / theme = inherit defaults. Only set when
    /// the user explicitly picked something in the style section.
    let onCreate: (
        _ databaseId: String?,
        _ propertyValues: [String: PropertyValueFfi],
        _ standalone: StandaloneStyle
    ) -> Void
    let onCancel: () -> Void

    /// Captures the per-doc style overrides the user picked at
    /// creation time when the note is NOT being filed in a database.
    struct StandaloneStyle: Equatable {
        var cover: String? = nil
        var icon: String? = nil
        var theme: String? = nil
        /// Optional RFC 3339 timestamp used to backdate the new
        /// doc's `published_at`. `nil` = the SQLite store falls
        /// back to the row's `created_at` (default behaviour). Set
        /// when the user pre-picks a publish date on the creation
        /// sheet.
        var publishedAt: String? = nil
        /// Raw bytes of a user-picked cover image (PhotosPicker or
        /// fileImporter). `nil` = no custom cover ; the gradient
        /// catalogue in `cover` is used as-is. When set, the store
        /// writes the bytes into the covers directory once the
        /// docId is known and replaces `cover` with the resulting
        /// filename — keeps the SQLite contract (cover is a short
        /// string) without leaking image bytes into the meta row.
        var customCoverData: Data? = nil
        /// File extension to use when persisting `customCoverData`.
        /// Defaults to `"jpg"` ; PhotosPicker normalises to JPEG
        /// when reading via `loadTransferable(type: Data.self)`,
        /// fileImporter preserves the original (`heic`, `png`, …).
        var customCoverExt: String = "jpg"
    }

    @FocusState private var focused: Bool
    @State private var attachToDatabase: Bool = false
    @State private var pickedDatabaseId: String? = nil
    @State private var pickedDatabase: DatabaseFfi? = nil
    @State private var pickedDatabaseLoading: Bool = false
    @State private var propertyValues: [String: PropertyValueFfi] = [:]
    @State private var standaloneStyle: StandaloneStyle = .init()
    @State private var showingEmojiPicker = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false

    var body: some View {
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

                // Document-style section — always visible when the
                // doc-creation FFI is wired. Cover / icon / theme
                // live on the Document itself ; they're orthogonal
                // to the DB membership so we keep them around even
                // when the toggle below files the note as a DB row.
                if api != nil {
                    Section("Style") {
                        coverPicker
                        iconPicker
                        themePicker
                        publishDatePicker
                    }
                }

                if api != nil && !availableDatabases.isEmpty {
                    Section {
                        Toggle("Add to a database", isOn: $attachToDatabase)
                            .onChange(of: attachToDatabase) { _, isOn in
                                Haptic.toggle()
                                if !isOn {
                                    pickedDatabaseId = nil
                                    pickedDatabase = nil
                                    propertyValues = [:]
                                }
                            }
                    } footer: {
                        Text("Off (default): creates a stand-alone note. On: file the note as a row of an existing database — pick which one and fill the columns inline.")
                    }

                    if attachToDatabase {
                        Section("Database") {
                            Picker("Database", selection: Binding(
                                get: { pickedDatabaseId },
                                set: { newId in
                                    pickedDatabaseId = newId
                                    Haptic.tap()
                                    loadDatabaseSchema()
                                }
                            )) {
                                Text("Choose…").tag(String?.none)
                                ForEach(availableDatabases, id: \.id) { db in
                                    Text(db.titlePlain.isEmpty ? "Untitled" : db.titlePlain)
                                        .tag(Optional(db.id))
                                }
                            }
                        }

                        if pickedDatabaseLoading {
                            Section { ProgressView().frame(maxWidth: .infinity) }
                        } else if let db = pickedDatabase {
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
        // Same gradient catalogue as DocumentDecor / DatabaseHeader
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
                            Label("From Files", systemImage: "folder")
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
                            label: name,
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
                        DocumentViewModel.imageExtension(url.pathExtension)
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
        label: String,
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
    /// `update_document_published_at` right after the doc lands.
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
        // an actual database before we let the submit fire.
        if attachToDatabase && pickedDatabaseId == nil { return false }
        return true
    }

    private func commit() {
        guard canCommit else { return }
        // Style + DB membership are orthogonal — the doc keeps its
        // chosen cover / icon / theme whether or not it's also
        // filed as a row of a database.
        onCreate(attachToDatabase ? pickedDatabaseId : nil, propertyValues, standaloneStyle)
    }

    /// Properties of `db` that we want to render in the inline editor.
    /// We hide the system page-link property and the Title column —
    /// Title is filled with the doc title we already collect above.
    private func editableProperties(of db: DatabaseFfi) -> [PropertyFfi] {
        db.properties.filter { prop in
            if prop.name == "__pinkha_page__" { return false }
            if case .title = prop.propertyType { return false }
            return true
        }
    }

    private func loadDatabaseSchema() {
        guard let dbId = pickedDatabaseId,
              let api else {
            pickedDatabase = nil
            propertyValues = [:]
            return
        }
        pickedDatabaseLoading = true
        Task.detached(priority: .userInitiated) {
            let json = try? api.getDatabaseJson(id: dbId)
            let decoded: DatabaseFfi? = json
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(DatabaseFfi.self, from: $0) }
            await MainActor.run {
                pickedDatabase = decoded
                propertyValues = [:]
                pickedDatabaseLoading = false
            }
        }
    }
}

/// Inline editor for a single property — picked based on the property
/// type. Mirrors the cell widgets used by DatabaseTableView in spirit,
/// but is self-contained so the sheet doesn't reach across the
/// database internals.
struct PropertyInputRow: View {
    let property: PropertyFfi
    @Binding var value: PropertyValueFfi

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: property.propertyType.icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(property.name)
                    .font(.subheadline.weight(.medium))
                editor
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch property.propertyType {
        case .text:
            TextField("Text", text: textBinding(get: {
                if case .text(let s) = value { return s }; return ""
            }, set: { value = $0.isEmpty ? .empty : .text($0) }))
                .textFieldStyle(.plain)
        case .number:
            TextField("Number", text: textBinding(get: {
                if case .number(let n) = value { return n.formatted() }; return ""
            }, set: { v in
                if let n = Double(v) { value = .number(n) }
                else if v.isEmpty { value = .empty }
            }))
                .keyboardType(.decimalPad)
                .textFieldStyle(.plain)
        case .checkbox:
            Toggle("", isOn: Binding(
                get: { if case .checkbox(let b) = value { return b }; return false },
                set: { value = .checkbox($0) }
            ))
            .labelsHidden()
        case .url:
            TextField("https://", text: textBinding(get: {
                if case .url(let s) = value { return s }; return ""
            }, set: { value = $0.isEmpty ? .empty : .url($0) }))
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.plain)
        case .date:
            DatePicker("", selection: Binding(
                get: { dateFromValue() ?? .now },
                set: { value = .date(isoDay($0)) }
            ), displayedComponents: .date)
                .labelsHidden()
        case .selection(let options):
            Picker("", selection: Binding(
                get: { if case .selection(let s) = value, let s { return s }; return "" },
                set: { value = $0.isEmpty ? .empty : .selection($0) }
            )) {
                Text("None").tag("")
                ForEach(options, id: \.self) { opt in Text(opt).tag(opt) }
            }
            .labelsHidden()
        case .selectionMultiple(let options):
            MultiSelectInline(options: options, value: $value)
        default:
            Text(value.displayText.isEmpty ? "—" : value.displayText)
                .foregroundStyle(.secondary)
        }
    }

    /// Small wrapper that bridges the closure-based getter / setter
    /// to a Binding<String> usable by TextField.
    private func textBinding(get: @escaping () -> String,
                             set: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: get, set: set)
    }

    private func dateFromValue() -> Date? {
        if case .date(let s) = value {
            var fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
            return fmt.date(from: s)
        }
        return nil
    }

    private func isoDay(_ d: Date) -> String {
        var fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
        return fmt.string(from: d)
    }
}

/// Pill-style multi-select inline. Tapping a chip toggles it. We
/// stay flat (no presentation sheet) so the user keeps context with
/// the title field above.
private struct MultiSelectInline: View {
    let options: [String]
    @Binding var value: PropertyValueFfi

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { opt in
                    let on = isSelected(opt)
                    Button {
                        Haptic.tap()
                        toggle(opt)
                    } label: {
                        Text(opt)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                                        in: Capsule(style: .continuous))
                            .foregroundStyle(on ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func isSelected(_ opt: String) -> Bool {
        if case .selectionMultiple(let vs) = value { return vs.contains(opt) }
        return false
    }

    private func toggle(_ opt: String) {
        var set: [String]
        if case .selectionMultiple(let vs) = value { set = vs } else { set = [] }
        if let idx = set.firstIndex(of: opt) { set.remove(at: idx) } else { set.append(opt) }
        value = set.isEmpty ? .empty : .selectionMultiple(set)
    }
}

// ── Cover image view ─────────────────────────────────────────────────────────

/// Renders a document cover from the value stored on `Document.cover` —
/// local filename in the covers directory, `file://` URL, remote
/// `http(s)://` URL, gradient preset (`cover.aurora` / `forest` /
/// `sunset` / `ocean`), or a soft default when the value is empty / nil.
///
/// Shared between the document editor's banner and the home view's
/// recent cards so a doc looks the same in both places (Notion-style).
struct CoverImageView: View {
    let cover: String?

    var body: some View {
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
            guard let directory = try? DocumentViewModel.coversDirectory() else { return nil }
            return UIImage(contentsOfFile: directory.appendingPathComponent(id).path)
        }
        guard let url = URL(string: id), url.isFileURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
