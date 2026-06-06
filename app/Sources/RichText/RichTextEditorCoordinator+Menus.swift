import UIKit

// ── Extension Menus ───────────────────────────────────────────────────────────

extension RichTextEditorCoordinator {

    // Color dropdown menu. Content is lazily computed via `UIDeferredMenuElement.uncached`:
    // the closure runs at each menu opening — the reliable point for hiding the pill
    // at the exact moment of presentation (`.touchDown` is consumed by the gesture recognizer
    // of `showsMenuAsPrimaryAction`).
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
        // `UIAction(title:)` takes a raw `String` — UIKit does NOT route
        // through the `Localizable.xcstrings` catalogue automatically the
        // way SwiftUI does with `LocalizedStringKey`. We explicitly resolve
        // each label via `String(localized:)` so the popup speaks the
        // user's preferred language.
        let palette: [(String, UIColor, String)] = [
            ("rouge",  .systemRed,    String(localized: "Red")),
            ("rose",   .systemPink,   String(localized: "Pink")),
            ("orange", .systemOrange, String(localized: "Orange")),
            ("jaune",  .systemYellow, String(localized: "Yellow")),
            ("vert",   .systemGreen,  String(localized: "Green")),
            ("cyan",   .cyan,         String(localized: "Cyan")),
            ("bleu",   .systemBlue,   String(localized: "Blue")),
            ("violet", .systemPurple, String(localized: "Purple")),
            ("marron", .brown,        String(localized: "Brown")),
        ]
        let cfgDot = UIImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let cfgX   = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)

        let none = UIAction(
            title: String(localized: "None"),
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

    // ── Block color (¶) ───────────────────────────────────────────────────
    //
    // Same UI pattern as `colorMenu` but applies the chosen colour to the
    // whole block via the parent's `onSetBlockColor` closure (which calls
    // the FFI `set_block_color`). Block colour is the default foreground for
    // spans without an inline `.color(...)` — inline wins over block.

    func blockColorMenu(current: String?) -> UIMenu {
        let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            self.captureSelectionBeforeToolbar()
            self.menuPresentingUntil = Date().addingTimeInterval(0.7)
            self.setToolbarHidden(true)
            completion(self.blockColorMenuChildren(current: current))
        }
        return UIMenu(title: "", children: [deferred])
    }

    func blockColorMenuChildren(current: String?) -> [UIMenuElement] {
        // Same `String(localized:)` rule as `colorMenuChildren` — UIKit
        // popups don't auto-localize. See [[localizedstringkey-trap]].
        let palette: [(String, UIColor, String)] = [
            ("rouge",  .systemRed,    String(localized: "Red")),
            ("rose",   .systemPink,   String(localized: "Pink")),
            ("orange", .systemOrange, String(localized: "Orange")),
            ("jaune",  .systemYellow, String(localized: "Yellow")),
            ("vert",   .systemGreen,  String(localized: "Green")),
            ("cyan",   .cyan,         String(localized: "Cyan")),
            ("bleu",   .systemBlue,   String(localized: "Blue")),
            ("violet", .systemPurple, String(localized: "Purple")),
            ("marron", .brown,        String(localized: "Brown")),
        ]
        let cfgDot = UIImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let cfgX   = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)

        let none = UIAction(
            title: String(localized: "Default"),
            image: UIImage(systemName: "xmark", withConfiguration: cfgX)
        ) { [weak self] _ in
            self?.parent.onSetBlockColor?(nil)
            self?.menuPresentingUntil = nil
            self?.setToolbarHidden(false)
        }
        if current == nil { none.state = .on }

        let items = palette.map { (nom, couleur, label) -> UIAction in
            let img = UIImage(systemName: "circle.fill", withConfiguration: cfgDot)?
                .withTintColor(couleur, renderingMode: .alwaysOriginal)
            let action = UIAction(title: label, image: img) { [weak self] _ in
                self?.parent.onSetBlockColor?(nom)
                self?.menuPresentingUntil = nil
                self?.setToolbarHidden(false)
            }
            if current == nom { action.state = .on }
            return action
        }
        return [none] + items
    }

    func updateBlockColorButton(_ current: String?) {
        guard let btn = btnBlockColor else { return }
        let c: UIColor = current.map { uiColorFromName($0) } ?? .secondaryLabel
        let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        btn.setImage(UIImage(systemName: "paragraphsign", withConfiguration: cfg)?
            .withTintColor(c, renderingMode: .alwaysOriginal), for: .normal)
        btn.menu = blockColorMenu(current: current)
    }

    // Same pattern for B/I/U/S — deferred element for the reliable presentation hook.
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
            styleAction(label: String(localized: "Bold"),
                        symbol: "bold",          active: bold)      { [weak self] in self?.toggleBold() },
            styleAction(label: String(localized: "Italic"),
                        symbol: "italic",        active: italic)    { [weak self] in self?.toggleItalic() },
            styleAction(label: String(localized: "Underline"),
                        symbol: "underline",     active: underline) { [weak self] in self?.toggleUnderline() },
            styleAction(label: String(localized: "Strikethrough"),
                        symbol: "strikethrough", active: strike)    { [weak self] in self?.toggleStrike() },
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
