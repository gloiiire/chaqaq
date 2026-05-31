import SwiftUI
import UIKit

// ── RichTextEditor ────────────────────────────────────────────────────────────

/// `UIViewRepresentable` encapsulant `ExpandingTextView` avec édition rich text complète :
/// gras/italique/souligné/barré/couleur/lien via une pill toolbar glass,
/// raccourcis markdown, sauts de ligne Shift+Enter, et intégration undo/redo.
struct RichTextEditor: UIViewRepresentable {
    typealias Coordinator = RichTextEditorCoordinator

    @Binding var spans: [InlineTextFfi]
    @Binding var isFocused: Bool
    @Environment(\.isEnabled) var isEnabled
    var placeholder: String = ""
    var baseFont: UIFont = .preferredFont(forTextStyle: .body)
    var extraAttrs: [NSAttributedString.Key: Any]? = nil
    var focusCursorAt: Int? = nil
    var onSave: (() -> Void)?
    var onSaveSpans: (([InlineTextFfi]) -> Void)? = nil
    var onNewBlock: (([InlineTextFfi]) -> Void)?
    var onDeleteBloc: (() -> Void)?
    var onMergeAvecPrecedent: (([InlineTextFfi]) -> Void)?
    var onConvert: ((BlockContentFfi) -> Void)?
    var onLongPressSelection: (() -> Void)? = nil
    var onNavigatePrevious: (() -> Void)? = nil
    var onNavigateNext: (() -> Void)? = nil
    var onStopNavigationRepeat: (() -> Void)? = nil
    // Undo/redo câblés sur l'UndoManager du VM, exposés dans la pill clavier.
    // `*Provider` = closures live qui lisent l'état courant du VM (pas un snapshot
    // capturé à body time). Appelées par le Coordinator dans updateUIView,
    // textViewDidChange et textViewDidChangeSelection — couvre frappe, undo/redo
    // et changements de sélection.
    var onUndo: (() -> Void)? = nil
    var onRedo: (() -> Void)? = nil
    var canUndoProvider: (() -> Bool)? = nil
    var canRedoProvider: (() -> Bool)? = nil

    func makeUIView(context: Context) -> ExpandingTextView {
        let tv = ExpandingTextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.font = baseFont
        tv.textColor = .label
        tv.tintColor = pinkhaSelectionTint
        tv.isEditable = isEnabled
        tv.isSelectable = isEnabled
        tv.typingAttributes = [.font: baseFont, .foregroundColor: UIColor.label]
        tv.allowsEditingTextAttributes = true
        tv.isScrollEnabled = false
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainerInset = UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
        tv.inputAccessoryView = context.coordinator.makeToolbar()
        context.coordinator.tv = tv
        let coord = context.coordinator
        tv.onShiftEnter = { [weak coord] in
            coord?.shiftEnterTyped = true
            coord?.tv?.insertText("\n")
            coord?.shiftEnterTyped = false
        }
        tv.onToggleBold      = { [weak coord] in coord?.toggleBold() }
        tv.onToggleItalic    = { [weak coord] in coord?.toggleItalic() }
        tv.onToggleUnderline = { [weak coord] in coord?.toggleUnderline() }
        tv.onNavigatePrevious  = { [weak coord] in coord?.parent.onNavigatePrevious?() }
        tv.onNavigateNext      = { [weak coord] in coord?.parent.onNavigateNext?() }
        tv.onStopNavigationRepeat = { [weak coord] in coord?.parent.onStopNavigationRepeat?() }
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(RichTextEditorCoordinator.handleLongPressSelection(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        tv.addGestureRecognizer(longPress)
        if spans.isEmpty { tv.attributedText = context.coordinator.placeholder() }
        else { tv.attributedText = withExtras(spansToAttributed(spans, police: baseFont)) }
        return tv
    }

    func updateUIView(_ tv: ExpandingTextView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        coord.updateUndoRedoButtons()
        tv.tintColor = pinkhaSelectionTint
        tv.isEditable = isEnabled
        tv.isSelectable = isEnabled
        if !isEnabled && tv.isFirstResponder {
            tv.resignFirstResponder()
            DispatchQueue.main.async { isFocused = false }
        }

        // Sauter la recomputation quand les spans n'ont pas changé : SwiftUI re-rend
        // tout le ForEach à chaque frappe (typiquement pour un seul bloc) ; inutile
        // de reconstruire NSAttributedString pour les N-1 autres blocs inchangés.
        if coord.lastSyncedSpans != spans {
            // Ne pas réassigner tv.font pendant l'édition : UITextView.font réapplique
            // la police à TOUT le texte et effacerait le gras/italique par caractère.
            let editingText: NSAttributedString = spans.isEmpty
                ? NSAttributedString(string: "",
                                      attributes: [.font: baseFont, .foregroundColor: UIColor.label])
                : withExtras(spansToAttributed(spans, police: baseFont))
            if !coord.isEditing {
                tv.font = baseFont
                tv.attributedText = spans.isEmpty ? coord.placeholder() : editingText
            } else if tv.attributedText.string != editingText.string {
                // Undo/redo pendant l'édition : le VM a changé les spans sans passer
                // par le clavier. Restaurer le curseur à la fin du texte restauré.
                let savedTyping = tv.typingAttributes
                tv.attributedText = editingText
                tv.typingAttributes = savedTyping
                tv.selectedRange = NSRange(location: editingText.length, length: 0)
            }
            coord.lastSyncedSpans = spans
        }

        if isFocused && !tv.isFirstResponder {
            let pos = focusCursorAt
            DispatchQueue.main.async {
                _ = tv.becomeFirstResponder()
                let loc = pos.map { min($0, tv.text.count) } ?? tv.text.count
                tv.selectedRange = NSRange(location: loc, length: 0)
            }
        } else if !isFocused && tv.isFirstResponder {
            tv.resignFirstResponder()
        }
    }

    /// Superpose `extraAttrs` (ex. barré pour todo) sur les attributs dérivés des spans.
    private func withExtras(_ attr: NSAttributedString) -> NSAttributedString {
        guard let extras = extraAttrs, !extras.isEmpty else { return attr }
        let m = NSMutableAttributedString(attributedString: attr)
        m.addAttributes(extras, range: NSRange(location: 0, length: m.length))
        return m
    }

    func makeCoordinator() -> RichTextEditorCoordinator { RichTextEditorCoordinator(parent: self) }
}
