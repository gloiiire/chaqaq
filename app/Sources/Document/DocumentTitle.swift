import SwiftUI

// ── Document title ────────────────────────────────────────────────────────────

/// SwiftUI wrapper that manages focus for the document title editor.
struct DocumentTitleView: View {
    @Binding var title: String
    @Binding var focusDemande: Bool
    let onSave: () -> Void
    let onNewBlock: (String) -> Void
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

/// `UIViewRepresentable` wrapping an `ExpandingTextView` for the document title field.
/// Intercepts newline insertion to trigger block creation instead.
private struct TitleEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    let onSave: () -> Void
    let onNewBlock: (String) -> Void

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
            NSAttributedString(string: "Untitled",
                               attributes: [.font: parent.police, .foregroundColor: UIColor.tertiaryLabel])
        }

        func textViewDidBeginEditing(_ tv: UITextView) {
            isEditing = true
            parent.isFocused = true
            // Clear the placeholder when editing begins.
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
            // Enter in the title: keep text before the newline as title,
            // move text after the newline into a new block below.
            if let idx = text.firstIndex(of: "\n") {
                let before = String(text[text.startIndex..<idx])
                let after  = String(text[text.index(after: idx)...])
                tv.text = before
                parent.text = before
                parent.onSave()
                parent.onNewBlock(after)
                return
            }
            parent.text = text
        }
    }
}
