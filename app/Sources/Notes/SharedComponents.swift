import SwiftUI

// ── Composants partagés ────────────────────────────────────────────────────────

/// Entête de section en majuscules avec style caption semi-gras.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
    }
}

/// Salutation affichée en haut de l'onglet Notes.
struct GreetingHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.largeTitle.bold())
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Placeholder affiché quand il n'y a encore aucun document.
struct NotesEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Aucun document").font(.headline)
                Text("Appuie sur le bouton en bas à droite\npour créer ta première note.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Bouton flottant partagé entre l'accueil (square.and.pencil) et l'éditeur (pencil.and.outline).
/// Effet glass + animation pulse + haptic feedback.
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

/// `ButtonStyle` personnalisé pour `FloatingButton` : effet glass, zoom à l'appui, ombre colorée.
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

/// Une ligne dans la liste de documents : icône, titre et date relative.
struct DocumentRow: View {
    let doc: DocumentMetaFfi

    var body: some View {
        HStack(spacing: 12) {
            documentIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(doc.titlePlain.isEmpty ? "Sans titre" : doc.titlePlain)
                    .font(.body.weight(.medium))
                if let date = formattedDate(doc.updatedAt) {
                    Text(date).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    /// Affiche l'icône du document : emoji personnalisé depuis UserDefaults, ou image système générique.
    @ViewBuilder
    private var documentIcon: some View {
        if let icon = UserDefaults.standard.string(forKey: Self.iconKey(docId: doc.id)), !icon.isEmpty {
            Text(icon).font(.title2).frame(width: 34, height: 34)
        } else {
            Image(systemName: "doc.text")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.secondary.opacity(0.12),
                             in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private static func iconKey(docId: String) -> String { "document.icon.\(docId)" }

    private func formattedDate(_ iso: String) -> String? {
        guard !iso.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

/// Sheet de création d'un nouveau document. Accepte un titre et appelle `onCreate` ou `onCancel`.
struct CreateDocumentSheet: View {
    @Binding var title: String
    let onCreate: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titre du document", text: $title)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit {
                            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            onCreate()
                        }
                }
            }
            .navigationTitle("Nouveau document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onCancel) { Image(systemName: "xmark") }
                        .accessibilityLabel("Annuler")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { onCreate() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("Créer")
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }
}
