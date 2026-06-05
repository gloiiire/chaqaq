import SwiftUI

// ── Shared components ─────────────────────────────────────────────────────────

/// Section header in uppercase with semi-bold caption style.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
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

/// Floating button shared between the home screen (square.and.pencil) and the editor (pencil.and.outline).
/// Glass effect + pulse animation + haptic feedback.
struct FloatingButton: View {
    let icon: String
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.58)) { pulse = true }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(.easeOut(duration: 0.18)) { pulse = false }
            }
        } label: {
            ZStack {
                if pulse {
                    Circle()
                        .fill(Color("SelectionTint").opacity(0.18))
                        .frame(width: 54, height: 54)
                        .transition(.scale.combined(with: .opacity))
                }
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .symbolEffect(.bounce, value: pulse)
            }
            .frame(width: 54, height: 54)
            .contentShape(Circle())
        }
        .buttonStyle(FloatingButtonStyle())
        .sensoryFeedback(.impact(flexibility: .soft), trigger: pulse)
    }
}

/// Custom `ButtonStyle` for `FloatingButton`: glass effect, press zoom, colored shadow.
private struct FloatingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassEffect(.regular.interactive(), in: .circle)
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .rotationEffect(.degrees(configuration.isPressed ? -6 : 0))
            .shadow(color: Color("SelectionTint").opacity(configuration.isPressed ? 0.34 : 0.18),
                    radius: configuration.isPressed ? 20 : 12,
                    y: configuration.isPressed ? 8 : 6)
            .animation(.spring(response: 0.22, dampingFraction: 0.62), value: configuration.isPressed)
    }
}


/// Sheet for creating a new note or database. Accepts a title and calls `onCreate` or `onCancel`.
struct CreateDocumentSheet: View {
    @Binding var title: String
    var prompt: String = "Document title"
    /// Navigation title — defaults to "New" but each call site sets a
    /// more descriptive label (e.g. "New Document", "New Database") so the
    /// user knows what they're creating before they type.
    var navigationTitle: String = "New"
    let onCreate: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(prompt, text: $title)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit {
                            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            onCreate()
                        }
                }
            }
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
                    Button { onCreate() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("Create")
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { focused = true }
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
