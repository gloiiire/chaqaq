import UIKit
import SwiftUI

// ── Coordinator RichTextEditor ────────────────────────────────────────────────

/// Coordinator de `RichTextEditor` : délégué UITextView + gestionnaire de la toolbar pill.
/// Défini au niveau du module pour permettre les extensions dans des fichiers séparés.
final class RichTextEditorCoordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {

    var parent: RichTextEditor
    weak var tv: ExpandingTextView?
    var isEditing = false
    var isDeleting = false
    var shiftEnterTyped = false
    var lastSelection = NSRange(location: 0, length: 0)
    // Couleur en cours de frappe sans sélection : UIKit réinitialise typingAttributes
    // après chaque caractère (et l'ouverture d'un menu peut resign first responder),
    // donc on ré-injecte la couleur juste avant chaque insertion.
    var pendingColor: String? = nil
    var toolbarActionInProgress = false
    var selectionGeneration = 0
    weak var btnTextStyle: UIButton?
    weak var btnColor: UIButton?
    weak var btnPaste: UIButton?
    weak var btnUndo: UIButton?
    weak var btnRedo: UIButton?
    var lastCanUndo: Bool?
    var lastCanRedo: Bool?
    /// Spans déjà synchronisés avec la text view — permet de sauter la recomputation
    /// `spansToAttributed` lors des re-renders SwiftUI où les spans de ce bloc n'ont pas changé.
    var lastSyncedSpans: [InlineTextFfi]?
    // La pill toolbar — animée à alpha 0 quand un menu déroulant s'ouvre
    // (style Notes.app : la toolbar s'efface pendant que le menu est visible).
    weak var toolbarPill: UIView?
    var toolbarHidden = false
    // Fenêtre de garde : pendant ~700 ms après l'ouverture d'un menu, ignorer les
    // `textViewDidChangeSelection` parasites qu'UIKit émet pendant la présentation
    // (sinon la pill clignote ou ne se cache jamais).
    var menuPresentingUntil: Date?

    init(parent: RichTextEditor) {
        self.parent = parent
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pasteboardChanged),
            name: UIPasteboard.changedNotification,
            object: nil)
    }

    @objc func pasteboardChanged() {
        DispatchQueue.main.async { [weak self] in self?.updatePasteButton() }
    }

    @objc func handleLongPressSelection(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        parent.onLongPressSelection?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    func placeholder() -> NSAttributedString {
        guard parent.isEnabled else { return NSAttributedString(string: "") }
        return NSAttributedString(string: parent.placeholder,
                                  attributes: [.foregroundColor: UIColor.tertiaryLabel,
                                               .font: parent.baseFont])
    }

    // ── UITextViewDelegate ────────────────────────────────────────────────────

    func textViewDidBeginEditing(_ tv: UITextView) {
        isEditing = true
        parent.isFocused = true
        rememberSelection(tv.selectedRange, length: tv.attributedText.length)
        // Effacer le placeholder quand l'édition commence.
        if tv.textColor == .tertiaryLabel {
            tv.attributedText = NSAttributedString(string: "", attributes: [
                .font: parent.baseFont,
                .foregroundColor: UIColor.label
            ])
        }
        tv.typingAttributes = [.font: parent.baseFont, .foregroundColor: UIColor.label]
        updateToolbar()
    }

    func textViewDidChangeSelection(_ tv: UITextView) {
        let selection = normalizedSelection(tv.selectedRange, length: tv.attributedText.length)
        if selection.length > 0 {
            rememberSelection(selection, length: tv.attributedText.length)
        } else {
            cleanRememberedIfStillEmpty(tv)
        }
        updateToolbar()
        updateUndoRedoButtons()
        // Si l'utilisateur a fermé un menu (tap dans le texte → sélection changée),
        // restaurer la pill au cas où elle serait encore cachée.
        // Sauter pendant la fenêtre de garde pour éviter d'annuler le hide demandé.
        if let until = menuPresentingUntil, Date() < until { return }
        menuPresentingUntil = nil
        setToolbarHidden(false)
    }

    func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Retour arrière sur un bloc vide → supprimer le bloc
        if text.isEmpty, range == NSRange(location: 0, length: 0), tv.text.isEmpty {
            isDeleting = true
            DispatchQueue.main.async { [weak self] in self?.parent.onDeleteBloc?() }
            return false
        }
        // Retour arrière en début de bloc non vide → fusionner avec le bloc précédent
        if text.isEmpty, range == NSRange(location: 0, length: 0), !tv.text.isEmpty,
           parent.onMergeAvecPrecedent != nil {
            isDeleting = true
            let currentSpans = attributedToSpans(tv.attributedText, police: parent.baseFont)
            DispatchQueue.main.async { [weak self] in
                self?.parent.onMergeAvecPrecedent?(currentSpans)
            }
            return false
        }
        // Touche Entrée
        if text == "\n" {
            if shiftEnterTyped {
                // Shift+Enter : laisser le saut de ligne s'insérer normalement
                shiftEnterTyped = false
                return true
            }
            // Entrée normal : diviser le bloc et en créer un nouveau.
            // Préserver les attributs (couleur, gras…) de la portion après le curseur.
            let afterStart = range.location + range.length
            let attrBefore = tv.attributedText.attributedSubstring(
                from: NSRange(location: 0, length: range.location))
            let attrAfter = tv.attributedText.attributedSubstring(
                from: NSRange(location: afterStart, length: tv.attributedText.length - afterStart))
            let afterSpans = attributedToSpans(attrAfter, police: parent.baseFont)
            tv.attributedText = attrBefore.string.isEmpty
                ? NSAttributedString(string: "", attributes: [.font: parent.baseFont, .foregroundColor: UIColor.label])
                : attrBefore
            tv.selectedRange = NSRange(location: attrBefore.length, length: 0)
            save(attributedToSpans(attrBefore, police: parent.baseFont))
            parent.onNewBlock?(afterSpans)
            return false
        }
        // Couleur de frappe : UIKit réinitialise typingAttributes après chaque caractère,
        // on ré-injecte donc la couleur juste avant l'insertion.
        if !text.isEmpty, text != "\n", let nom = pendingColor {
            tv.typingAttributes[.foregroundColor] = uiColorFromName(nom)
            tv.typingAttributes[.pinkhaColor]     = nom
        }
        return true
    }

    func textViewDidEndEditing(_ tv: UITextView) {
        isEditing = false
        parent.isFocused = false
        guard !isDeleting else { return }
        save(attributedToSpans(tv.attributedText, police: parent.baseFont))
        if parent.spans.isEmpty { tv.attributedText = placeholder() }
    }

    func textViewDidChange(_ tv: UITextView) {
        let text = tv.text ?? ""

        if let shortcut = markdownShortcut(for: text) {
            parent.onConvert?(shortcut)
            return
        }

        // save() = mettre à jour parent.spans + appeler onSaveSpans → vm.saveBlock → capture l'ancre burst pour undo.
        // Appelé à chaque frappe pour que canUndo soit true dès le premier caractère.
        save(attributedToSpans(tv.attributedText, police: parent.baseFont))
        if tv.selectedRange.length == 0 { clearRememberedSelection() }
        tv.invalidateIntrinsicContentSize()
        updateUndoRedoButtons()
    }

    // ── Sauvegarde ────────────────────────────────────────────────────────────

    func save(_ spans: [InlineTextFfi]) {
        parent.spans = spans
        if let onSaveSpans = parent.onSaveSpans {
            onSaveSpans(spans)
        } else {
            parent.onSave?()
        }
    }
}
