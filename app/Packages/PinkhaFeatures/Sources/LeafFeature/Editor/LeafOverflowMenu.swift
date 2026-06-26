import SwiftUI
import UIKit
import PinkhaCore

// ── Leaf overflow menu (UIKit bridge) ────────────────────────────────────────
//
// Why a UIKit bridge instead of SwiftUI `Menu` :
// • SwiftUI exposes no popover-lifecycle hook (no `isPresented:` binding,
//   no onPresent/onDismiss callback in the iOS 26 swiftinterface).
// • We need that lifecycle because iOS 26 dims any menu popover that
//   opens over visible `.glassEffect()` surfaces — confirmed by bisect
//   on 2026-06-26. Our floating overlays (FAB + UndoRedoPill) are glass
//   and trigger the dim. We hide them while the popover is on screen,
//   restore once it's gone. Apple Notes uses the same UIKit-menu path
//   (cf. class-dump of `ICNoteEditorActionMenu` from iOS 26.5 MobileNotes).
//
// **Open detection — at `touchDown`, NOT at popover present**. iOS 26
// captures the backdrop snapshot the moment the user lifts the finger,
// so hiding overlays at present-time is too late (snapshot already
// includes them → dim). `touchDown` runs before the menu presentation
// pipeline, giving SwiftUI one runloop turn to remove the glass surfaces
// before the snapshot is taken.
//
// **Close detection** — empirical 2026-06-26 :
// • `UIButton.menu` in iOS 26 does NOT use a separate `UIWindow`
//   (didBecomeVisible never fires).
// • `presentedViewController` does NOT change either — the menu adds
//   its chrome directly to the window's view tree.
// • `.menuActionTriggered` fires at OPEN (because the menu IS the
//   button's primary action), not at item selection — unusable.
// • Window-level `UITapGestureRecognizer` / long-press at minimumPress=0
//   are silently suppressed by iOS while the chrome is presented.
// • CoreAnimation presentation-opacity polling works but restores
//   overlays mid-dismiss-animation, causing a worse bug : re-opening
//   the menu before the anim finishes brings overlays back UNDER the
//   freshly-opening popover → dim.
//
// The signal that actually works : polling the window's total subview
// count. The chrome adds ~80 views on present, drops them at the end
// of the dismiss animation (after the visual fade-out completes). We
// accept the ~140 ms delay as the lesser evil — it guarantees overlays
// only reappear once the popover is fully gone.

public struct LeafOverflowMenuButton: UIViewRepresentable {

    // ── Live state ────────────────────────────────────────────────────────

    public let isLocked: Bool
    public let isPinned: Bool
    public let accentColorName: String?
    public let textDirection: String?
    public let theme: String?
    public let settingsThemeLabel: String
    public let availableThemes: [(rawValue: String, label: String)]
    public let accentPalette: [BlockColorOption]

    // ── Actions ───────────────────────────────────────────────────────────

    public let onToggleLock: () -> Void
    public let onTogglePin: () -> Void
    public let onSetAccent: (String?) -> Void
    public let onSetTextDirection: (String?) -> Void
    public let onSetTheme: (String?) -> Void
    public let onShowPublishDate: () -> Void
    public let onShowAttachToBook: () -> Void
    public let onToggleReaderMode: () -> Void
    public let onShare: (UIView) -> Void

    // ── Popover lifecycle (PRO-61 — drives overlay visibility) ────────────

    public let onMenuOpen: () -> Void
    public let onMenuClose: () -> Void

    public init(
        isLocked: Bool,
        isPinned: Bool,
        accentColorName: String?,
        textDirection: String?,
        theme: String?,
        settingsThemeLabel: String,
        availableThemes: [(rawValue: String, label: String)],
        accentPalette: [BlockColorOption],
        onToggleLock: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onSetAccent: @escaping (String?) -> Void,
        onSetTextDirection: @escaping (String?) -> Void,
        onSetTheme: @escaping (String?) -> Void,
        onShowPublishDate: @escaping () -> Void,
        onShowAttachToBook: @escaping () -> Void,
        onToggleReaderMode: @escaping () -> Void,
        onShare: @escaping (UIView) -> Void,
        onMenuOpen: @escaping () -> Void,
        onMenuClose: @escaping () -> Void
    ) {
        self.isLocked = isLocked
        self.isPinned = isPinned
        self.accentColorName = accentColorName
        self.textDirection = textDirection
        self.theme = theme
        self.settingsThemeLabel = settingsThemeLabel
        self.availableThemes = availableThemes
        self.accentPalette = accentPalette
        self.onToggleLock = onToggleLock
        self.onTogglePin = onTogglePin
        self.onSetAccent = onSetAccent
        self.onSetTextDirection = onSetTextDirection
        self.onSetTheme = onSetTheme
        self.onShowPublishDate = onShowPublishDate
        self.onShowAttachToBook = onShowAttachToBook
        self.onToggleReaderMode = onToggleReaderMode
        self.onShare = onShare
        self.onMenuOpen = onMenuOpen
        self.onMenuClose = onMenuClose
    }

    // ── UIViewRepresentable ──────────────────────────────────────────────

    public func makeCoordinator() -> Coordinator {
        Coordinator(onMenuOpen: onMenuOpen, onMenuClose: onMenuClose)
    }

    public func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.tintColor = .label
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "Leaf options")
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        // Open BEFORE iOS captures the dim backdrop snapshot (= at
        // touchDown, not at menu present). Cf. file header comment.
        button.addAction(UIAction { [coord = context.coordinator] _ in
            coord.handleOpen(from: button)
        }, for: .touchDown)
        // NB — we do NOT hook .touchCancel / .touchUpOutside /
        // .menuActionTriggered : empirical logs (2026-06-26) showed
        // that iOS itself cancels the button's touch tracking ~100 ms
        // after touchDown when it transitions into menu presentation
        // (which would fire .touchCancel and close us prematurely),
        // AND .menuActionTriggered fires at OPEN (not at item
        // selection) because the menu IS the primary action of this
        // button. The frame-poll on view count is the sole close
        // signal — the 0.6 s fallback covers genuine drag-off cancels.
        return button
    }

    public func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.onMenuOpen = onMenuOpen
        context.coordinator.onMenuClose = onMenuClose
        context.coordinator.button = button
        button.menu = buildMenu(sourceView: button, coordinator: context.coordinator)
    }

    // ── Coordinator (open/close lifecycle) ───────────────────────────────

    public final class Coordinator {
        var onMenuOpen: () -> Void
        var onMenuClose: () -> Void
        weak var button: UIButton?
        private var isOpen: Bool = false
        private var displayLink: CADisplayLink?
        /// Total view count under the button's window captured at
        /// touchDown. The menu's chrome adds ~80 views on present and
        /// tears them down at the end of the dismiss animation ;
        /// `current > baseline` → menu visible, `current ≤ baseline`
        /// after we've seen it grow → fully dismissed.
        private var baselineViewCount: Int = 0
        private var sawMenuPresented: Bool = false
        private var openedAt: CFTimeInterval = 0

        init(onMenuOpen: @escaping () -> Void, onMenuClose: @escaping () -> Void) {
            self.onMenuOpen = onMenuOpen
            self.onMenuClose = onMenuClose
        }

        func handleOpen(from button: UIButton) {
            guard !isOpen else { return }
            isOpen = true
            sawMenuPresented = false
            openedAt = CACurrentMediaTime()
            baselineViewCount = Coordinator.viewCount(under: button.window)
            onMenuOpen()
            startPolling()
        }

        private func startPolling() {
            displayLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func tick() {
            guard isOpen, let button = button else { return }
            let current = Coordinator.viewCount(under: button.window)
            if current > baselineViewCount {
                sawMenuPresented = true
                return
            }
            if sawMenuPresented {
                finishClose()
                return
            }
            if CACurrentMediaTime() - openedAt > 0.6 {
                // No menu ever appeared → user touched down then
                // drag-off-cancelled. Restore overlays.
                finishClose()
            }
        }

        private func finishClose() {
            isOpen = false
            sawMenuPresented = false
            baselineViewCount = 0
            displayLink?.invalidate()
            displayLink = nil
            onMenuClose()
        }

        /// Total number of `UIView`s in the window's view tree
        /// (recursive). Cheap : we only call this at touchDown and
        /// then once per frame while a menu is potentially open.
        private static func viewCount(under window: UIWindow?) -> Int {
            guard let window else { return 0 }
            return count(view: window)
        }

        private static func count(view: UIView) -> Int {
            var n = 1
            for sub in view.subviews { n += count(view: sub) }
            return n
        }

    }

    // ── Menu construction ────────────────────────────────────────────────

    private func buildMenu(sourceView: UIView, coordinator: Coordinator) -> UIMenu {
        // ── Apple-Music-style compact horizontal row : Lock / Pin /
        //    Share. iOS 16+ : setting `preferredElementSize = .small`
        //    on an inline UIMenu renders its action children as a
        //    horizontal row of icon-and-label buttons (matches the
        //    `.controlGroupStyle(.menu)` look from the old SwiftUI
        //    implementation).
        let lockAction = UIAction(
            title: isLocked ? String(localized: "Unlock") : String(localized: "Lock"),
            image: UIImage(systemName: isLocked ? "lock.fill" : "lock.open.fill")
        ) { _ in
            Haptic.toggle()
            onToggleLock()
        }
        let pinAction = UIAction(
            title: isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
            image: UIImage(systemName: isPinned ? "pin.slash" : "pin")
        ) { _ in
            Haptic.toggle()
            onTogglePin()
        }
        let shareAction = UIAction(
            title: String(localized: "Share"),
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [onShare] _ in
            onShare(sourceView)
        }
        // `.medium` matches Apple Notes : each child renders as an
        // icon centered above its label, three cells side-by-side
        // (vs `.small` which would drop the labels entirely).
        let primaryRow = UIMenu(
            title: "",
            options: .displayInline,
            preferredElementSize: .medium,
            children: [lockAction, pinAction, shareAction]
        )

        // ── Accent color picker ──────────────────────────────────────
        // No leading icon on the "default" row so iOS's trailing
        // checkmark (driven by `state: .on`) doesn't double up with
        // a redundant icon.
        let useDefaultAccent = UIAction(
            title: String(localized: "Use default"),
            state: accentColorName == nil ? .on : .off
        ) { [onSetAccent] _ in
            Haptic.tap()
            onSetAccent(nil)
        }
        let accentSwatches = accentPalette.map { option -> UIAction in
            UIAction(
                title: localized(option.displayName),
                image: option.swatchImage,
                state: accentColorName == option.name ? .on : .off
            ) { [onSetAccent, name = option.name] _ in
                Haptic.tap()
                onSetAccent(name)
            }
        }
        // Leading icon on the submenu row : the current accent's
        // swatch if one is set (= visual confirmation of selection,
        // shows which color is active without opening the submenu),
        // otherwise the neutral paintbrush.
        let accentRowImage: UIImage? = {
            if let name = accentColorName,
               let option = accentPalette.first(where: { $0.name == name }) {
                return option.swatchImage
            }
            return UIImage(systemName: "paintbrush")
        }()
        let accentMenu = UIMenu(
            title: String(localized: "Accent color"),
            image: accentRowImage,
            children: [useDefaultAccent] + accentSwatches
        )

        // ── Text direction picker ────────────────────────────────────
        let directionChildren: [UIAction] = [
            UIAction(
                title: String(localized: "System default"),
                state: textDirection == nil ? .on : .off
            ) { [onSetTextDirection] _ in
                Haptic.tap()
                onSetTextDirection(nil)
            },
            UIAction(
                title: String(localized: "Left to right"),
                image: UIImage(systemName: "text.alignleft"),
                state: textDirection == "ltr" ? .on : .off
            ) { [onSetTextDirection] _ in
                Haptic.tap()
                onSetTextDirection("ltr")
            },
            UIAction(
                title: String(localized: "Right to left"),
                image: UIImage(systemName: "text.alignright"),
                state: textDirection == "rtl" ? .on : .off
            ) { [onSetTextDirection] _ in
                Haptic.tap()
                onSetTextDirection("rtl")
            }
        ]
        let directionMenu = UIMenu(
            title: String(localized: "Text direction"),
            image: UIImage(systemName: textDirection == "rtl"
                           ? "text.alignright"
                           : (textDirection == "ltr"
                              ? "text.alignleft"
                              : "text.justify")),
            children: directionChildren
        )

        // ── Theme picker ─────────────────────────────────────────────
        let matchSettingsAction = UIAction(
            title: String(format: String(localized: "Match Settings (%@)"), settingsThemeLabel),
            state: theme == nil ? .on : .off
        ) { [onSetTheme] _ in
            Haptic.tap()
            onSetTheme(nil)
        }
        let themeChildren = availableThemes.map { entry -> UIAction in
            UIAction(
                title: entry.label,
                state: theme == entry.rawValue ? .on : .off
            ) { [onSetTheme, raw = entry.rawValue] _ in
                Haptic.tap()
                onSetTheme(raw)
            }
        }
        let themeMenu = UIMenu(
            title: String(localized: "Theme"),
            image: UIImage(systemName: "book.pages"),
            children: [matchSettingsAction] + themeChildren
        )

        // ── Single-tap actions ──────────────────────────────────────
        let publishAction = UIAction(
            title: String(localized: "Publish date"),
            image: UIImage(systemName: "paperplane")
        ) { [onShowPublishDate] _ in
            Haptic.tap()
            onShowPublishDate()
        }
        let attachAction = UIAction(
            title: String(localized: "Add to a book"),
            image: UIImage(systemName: "book.and.wrench.fill")
        ) { [onShowAttachToBook] _ in
            Haptic.tap()
            onShowAttachToBook()
        }
        let readerAction = UIAction(
            title: String(localized: "Reader mode"),
            image: UIImage(systemName: "eyeglasses")
        ) { [onToggleReaderMode] _ in
            onToggleReaderMode()
        }

        let middleGroup = UIMenu(
            title: "", options: .displayInline,
            children: [accentMenu, directionMenu, themeMenu]
        )
        let sheetGroup = UIMenu(
            title: "", options: .displayInline,
            children: [publishAction, attachAction]
        )
        let readerGroup = UIMenu(
            title: "", options: .displayInline,
            children: [readerAction]
        )

        return UIMenu(
            title: "",
            children: [primaryRow, middleGroup, sheetGroup, readerGroup]
        )
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    /// Resolves a `LocalizedStringKey` (SwiftUI-only) to a plain
    /// `String` for UIKit consumption. Mirror-based extraction of the
    /// underlying key, then standard NSLocalizedString lookup.
    private func localized(_ key: LocalizedStringKey) -> String {
        let mirror = Mirror(reflecting: key)
        let rawKey = mirror.children.first(where: { $0.label == "key" })?.value as? String
        guard let rawKey else { return "" }
        return NSLocalizedString(rawKey, comment: "")
    }
}
