import SwiftUI

// ── Titre du document ─────────────────────────────────────────────────────────

/// Wrapper SwiftUI qui gère le focus pour l'éditeur de titre du document.
struct DocumentTitleView: View {
    @Binding var title: String
    @Binding var focusDemande: Bool
    let onSave: () -> Void
    let onNewBlock: () -> Void
    @State private var focused = false

    var body: some View {
        TitleEditor(text: $title, isFocused: $focused,
                    onSave: onSave, onNewBlock: onNewBlock)
            .onChange(of: focusDemande) { _, requested in
                if requested {
                    focusDemande = false
                    DispatchQueue.main.async { focused = true }
                }
            }
    }
}

/// `UIViewRepresentable` wrappant un `ExpandingTextView` pour le champ titre du document.
/// Intercepte l'insertion de retour à la ligne pour déclencher la création de bloc à la place.
private struct TitleEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    let onSave: () -> Void
    let onNewBlock: () -> Void

    private let police = UIFont.systemFont(ofSize: 32, weight: .bold)

    func makeUIView(context: Context) -> ExpandingTextView {
        let tv = ExpandingTextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.font = police
        tv.tintColor = pinkhaSelectionTint
        tv.isEditable = isEnabled
        tv.isSelectable = isEnabled
        tv.isScrollEnabled = false
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        context.coordinator.tv = tv
        tv.attributedText = text.isEmpty
            ? context.coordinator.placeholderAttr()
            : NSAttributedString(string: text, attributes: [.font: police, .foregroundColor: UIColor.label])
        return tv
    }

    func updateUIView(_ tv: ExpandingTextView, context: Context) {
        context.coordinator.parent = self
        tv.tintColor = pinkhaSelectionTint
        tv.isEditable = isEnabled
        tv.isSelectable = isEnabled
        if !isEnabled && tv.isFirstResponder {
            tv.resignFirstResponder()
            DispatchQueue.main.async { isFocused = false }
        }
        if !context.coordinator.isEditing {
            tv.attributedText = text.isEmpty
                ? context.coordinator.placeholderAttr()
                : NSAttributedString(string: text, attributes: [.font: police, .foregroundColor: UIColor.label])
        }
        if isFocused && !tv.isFirstResponder {
            DispatchQueue.main.async {
                _ = tv.becomeFirstResponder()
                tv.selectedRange = NSRange(location: tv.text.count, length: 0)
            }
        } else if !isFocused && tv.isFirstResponder {
            tv.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TitleEditor
        weak var tv: ExpandingTextView?
        var isEditing = false

        init(parent: TitleEditor) { self.parent = parent }

        func placeholderAttr() -> NSAttributedString {
            NSAttributedString(string: "Sans titre",
                               attributes: [.font: parent.police, .foregroundColor: UIColor.tertiaryLabel])
        }

        func textViewDidBeginEditing(_ tv: UITextView) {
            isEditing = true
            parent.isFocused = true
            // Efface le placeholder quand l'édition commence.
            if tv.textColor == .tertiaryLabel {
                tv.attributedText = NSAttributedString(string: "",
                    attributes: [.font: parent.police, .foregroundColor: UIColor.label])
            }
            tv.typingAttributes = [.font: parent.police, .foregroundColor: UIColor.label]
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            isEditing = false
            parent.isFocused = false
            parent.text = tv.text ?? ""
            parent.onSave()
            if parent.text.isEmpty { tv.attributedText = placeholderAttr() }
        }

        func textViewDidChange(_ tv: UITextView) {
            guard let text = tv.text else { return }
            // Enter dans le titre : supprime le retour à la ligne et crée le premier bloc.
            if let idx = text.firstIndex(of: "\n") {
                tv.text = String(text[text.startIndex..<idx])
                parent.text = tv.text
                parent.onSave()
                parent.onNewBlock()
                return
            }
            parent.text = text
        }
    }
}
