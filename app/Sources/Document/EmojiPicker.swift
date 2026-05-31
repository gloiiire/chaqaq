import SwiftUI

// ── Persistance des emojis récents ────────────────────────────────────────────

let recentEmojisKey = "document.icon.recentEmojis"

/// Charge la liste des emojis récemment utilisés depuis UserDefaults.
func loadRecentEmojis() -> [String] {
    UserDefaults.standard.stringArray(forKey: recentEmojisKey) ?? []
}

/// Préfixe `emoji` à la liste des récents (plafonnée à 6), la persiste et retourne la nouvelle liste.
@discardableResult
func saveRecentEmoji(_ emoji: String) -> [String] {
    let existing = UserDefaults.standard.stringArray(forKey: recentEmojisKey) ?? []
    let liste = Array(([emoji] + existing.filter { $0 != emoji }).prefix(6))
    UserDefaults.standard.set(liste, forKey: recentEmojisKey)
    return liste
}

// ── Sélecteur d'emoji ─────────────────────────────────────────────────────────

/// Sheet plein écran pour sélectionner ou saisir un emoji comme icône de document.
struct EmojiPickerSheet: View {
    let selection: String?
    let recents: [String]
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var inputOpen = false

    private let categories: [(String, [String])] = [
        ("Smileys", ["😀", "😃", "😄", "😁", "😆", "🥹", "😊", "🙂", "🙃", "😉", "😍", "😘", "😎", "🤓", "🥳", "😤", "😭", "😱", "🤯", "😴", "🤫", "🤭", "🫡", "🤔","👁️","👁️‍🗨️"]),
        ("Mains", ["👋", "👌", "🤌", "🤏", "✌️", "🤞", "🫰", "🤟", "🤘", "👍", "👎", "👏", "🙌", "🫶", "🙏", "✍️", "💪"]),
        ("Nature", ["🐶", "🐱", "🦁", "🐯", "🦊", "🐻", "🐼", "🐸", "🐵", "🦋", "🐝", "🌿", "🌲", "🌊", "🔥", "🌙", "☀️", "⭐️", "✨", "🌈", "🌧️", "❄️"]),
        ("Objets", ["📌", "📎", "✏️", "🖊️", "📜","📚", "📖", "💡", "🔒", "🔑", "🧭", "🎧", "📷", "💻", "📱", "⌚️", "🎮", "🧩", "🎯"]),
        ("Symboles", ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💎", "⚡️", "✅", "❌", "‼️", "⁉️", "🔔", "🔕", "♾️", "☮️"])
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if inputOpen {
                        customInput
                    }

                    if !recents.isEmpty {
                        emojiSection(name: "Récents", emojis: recents)
                    }

                    ForEach(categories, id: \.0) { nom, emojis in
                        emojiSection(name: nom, emojis: emojis)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Icône")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Annuler")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            inputOpen.toggle()
                        }
                    } label: {
                        Image(systemName: "keyboard")
                    }
                    .accessibilityLabel("Saisir un emoji")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func validateInput() {
        guard let emoji = firstEmoji(input) else { return }
        onSelect(emoji)
        dismiss()
    }

    private var customInput: some View {
        HStack(spacing: 10) {
            TextField("Emoji", text: $input)
                .font(.system(size: 28))
                .textFieldStyle(.plain)
                .frame(height: 48)
                .padding(.horizontal, 14)
                .background(Color.secondary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .submitLabel(.done)
                .onSubmit { validateInput() }

            Button {
                validateInput()
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
            }
            .disabled(firstEmoji(input) == nil)
        }
    }

    private func emojiSection(name: String, emojis: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 10) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        onSelect(emoji)
                        dismiss()
                    } label: {
                        Text(emoji)
                            .font(.system(size: 30))
                            .frame(width: 44, height: 44)
                            .background(selection == emoji ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Retourne le premier caractère emoji dans `text`, ou `nil` s'il n'y en a pas.
    private func firstEmoji(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .first
            .map(String.init)
    }
}
