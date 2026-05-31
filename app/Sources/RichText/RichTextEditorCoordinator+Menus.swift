import UIKit

// ── Extension Menus ───────────────────────────────────────────────────────────

extension RichTextEditorCoordinator {

    // Menu déroulant couleur. Le contenu est calculé de façon paresseuse via `UIDeferredMenuElement.uncached` :
    // la closure s'exécute à chaque ouverture du menu — point fiable pour cacher la pill
    // au moment exact de la présentation (`.touchDown` est consommé par le gesture recognizer
    // de `showsMenuAsPrimaryAction`).
    func colorMenu(current: String?) -> UIMenu {
        let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            self.captureSelectionBeforeToolbar()
            self.menuPresentingUntil = Date().addingTimeInterval(0.7)
            self.setToolbarHidden(true)
            completion(self.colorMenuChildren(current: current))
        }
        return UIMenu(title: "", children: [deferred])
    }

    func colorMenuChildren(current: String?) -> [UIMenuElement] {
        let palette: [(String, UIColor, String)] = [
            ("rouge",  .systemRed,    "Rouge"),
            ("rose",   .systemPink,   "Rose"),
            ("orange", .systemOrange, "Orange"),
            ("jaune",  .systemYellow, "Jaune"),
            ("vert",   .systemGreen,  "Vert"),
            ("cyan",   .cyan,         "Cyan"),
            ("bleu",   .systemBlue,   "Bleu"),
            ("violet", .systemPurple, "Violet"),
            ("marron", .brown,        "Marron"),
        ]
        let cfgDot = UIImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let cfgX   = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)

        let none = UIAction(
            title: "Aucune",
            image: UIImage(systemName: "xmark", withConfiguration: cfgX)
        ) { [weak self] _ in
            self?.clearColor()
            self?.menuPresentingUntil = nil
            self?.setToolbarHidden(false)
        }
        if current == nil { none.state = .on }

        let items = palette.map { (nom, couleur, label) -> UIAction in
            let img = UIImage(systemName: "circle.fill", withConfiguration: cfgDot)?
                .withTintColor(couleur, renderingMode: .alwaysOriginal)
            let action = UIAction(title: label, image: img) { [weak self] _ in
                self?.applyColor(nom)
                self?.menuPresentingUntil = nil
                self?.setToolbarHidden(false)
            }
            if current == nom { action.state = .on }
            return action
        }
        return [none] + items
    }

    func updateColorButton(_ current: String?) {
        guard let btn = btnColor else { return }
        let iconName = current != nil ? "highlighter.badge.ellipsis" : "highlighter"
        let c: UIColor = current.map { uiColorFromName($0) } ?? .secondaryLabel
        let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        btn.setImage(UIImage(systemName: iconName, withConfiguration: cfg)?
            .withTintColor(c, renderingMode: .alwaysOriginal), for: .normal)
        btn.menu = colorMenu(current: current)
    }

    // Même pattern pour B/I/U/S — élément différé pour le hook fiable de présentation.
    func textStyleMenu(bold: Bool, italic: Bool, underline: Bool, strike: Bool) -> UIMenu {
        let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            self.captureSelectionBeforeToolbar()
            self.menuPresentingUntil = Date().addingTimeInterval(0.7)
            self.setToolbarHidden(true)
            completion(self.textStyleMenuChildren(bold: bold, italic: italic,
                                                  underline: underline, strike: strike))
        }
        return UIMenu(title: "", children: [deferred])
    }

    func textStyleMenuChildren(bold: Bool, italic: Bool, underline: Bool, strike: Bool) -> [UIMenuElement] {
        let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        func styleAction(label: String, symbol: String, active: Bool,
                         handler: @escaping () -> Void) -> UIAction {
            let img = UIImage(systemName: symbol, withConfiguration: cfg)
            let action = UIAction(title: label, image: img) { [weak self] _ in
                handler()
                self?.menuPresentingUntil = nil
                self?.setToolbarHidden(false)
            }
            if active { action.state = .on }
            return action
        }
        return [
            styleAction(label: "Gras",     symbol: "bold",          active: bold)      { [weak self] in self?.toggleBold() },
            styleAction(label: "Italique", symbol: "italic",        active: italic)    { [weak self] in self?.toggleItalic() },
            styleAction(label: "Souligné", symbol: "underline",     active: underline) { [weak self] in self?.toggleUnderline() },
            styleAction(label: "Barré",    symbol: "strikethrough", active: strike)    { [weak self] in self?.toggleStrike() },
        ]
    }

    func updateTextStyleButton(bold: Bool, italic: Bool, underline: Bool, strike: Bool) {
        guard let btn = btnTextStyle else { return }
        let anyActive = bold || italic || underline || strike
        let c: UIColor = anyActive ? (UIColor(named: "Accent") ?? .tintColor) : .secondaryLabel
        let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        btn.setImage(UIImage(systemName: "bold.italic.underline", withConfiguration: cfg)?
            .withTintColor(c, renderingMode: .alwaysOriginal), for: .normal)
        btn.menu = textStyleMenu(bold: bold, italic: italic, underline: underline, strike: strike)
    }
}
