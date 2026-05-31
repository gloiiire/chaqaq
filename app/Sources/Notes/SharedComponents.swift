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
            .navigationTitle("New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onCancel) { Image(systemName: "xmark") }
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
