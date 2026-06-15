import SwiftUI
import UIKit

// ── UIKit context menu wrapper ────────────────────────────────────────────────
//
// SwiftUI's native `.contextMenu` has a confirmed iOS 26 bug in
// horizontal `ScrollView` rows : the gesture recogniser is only
// registered on the first item, so long-pressing any later card lifts
// the first one's preview. Apple Music sidesteps this by using
// `UIContextMenuInteraction` directly on UIKit cells.
//
// This wrapper does the same — it hosts an arbitrary SwiftUI view
// inside a UIViewController and installs a UIContextMenuInteraction
// on the container, with a SwiftUI `preview` callback rendered via
// `UIHostingController`.

/// Wraps `content` in a UIKit host that owns a proper
/// `UIContextMenuInteraction`. Use this for cards inside horizontal
/// scrollers where SwiftUI's `.contextMenu` mis-routes the gesture.
struct UIKitContextMenu<Content: View, Preview: View>: UIViewControllerRepresentable {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let preview: () -> Preview
    /// `UIMenu` provider — typically returns a couple of `UIAction`s.
    let menu: () -> UIMenu
    /// Fired when the user taps the lifted preview itself.
    let onTapPreview: () -> Void

    func makeUIViewController(context: Context) -> HostController {
        HostController(rootView: AnyView(content()),
                       preview: { AnyView(preview()) },
                       menu: menu,
                       onTapPreview: onTapPreview)
    }

    func updateUIViewController(_ controller: HostController, context: Context) {
        controller.update(rootView: AnyView(content()),
                          preview: { AnyView(preview()) },
                          menu: menu,
                          onTapPreview: onTapPreview)
    }

    final class HostController: UIViewController, UIContextMenuInteractionDelegate {
        private let host: UIHostingController<AnyView>
        private var previewBuilder: () -> AnyView
        private var menuBuilder: () -> UIMenu
        private var onTapPreview: () -> Void

        init(rootView: AnyView,
             preview: @escaping () -> AnyView,
             menu: @escaping () -> UIMenu,
             onTapPreview: @escaping () -> Void) {
            self.host = UIHostingController(rootView: rootView)
            self.previewBuilder = preview
            self.menuBuilder = menu
            self.onTapPreview = onTapPreview
            super.init(nibName: nil, bundle: nil)
            // Transparent backgrounds so the SwiftUI parent's
            // backdrop shows through.
            view.backgroundColor = .clear
            host.view.backgroundColor = .clear
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            host.didMove(toParent: self)
            let interaction = UIContextMenuInteraction(delegate: self)
            view.addInteraction(interaction)
        }

        func update(rootView: AnyView,
                    preview: @escaping () -> AnyView,
                    menu: @escaping () -> UIMenu,
                    onTapPreview: @escaping () -> Void) {
            host.rootView = rootView
            self.previewBuilder = preview
            self.menuBuilder = menu
            self.onTapPreview = onTapPreview
        }

        // ── UIContextMenuInteractionDelegate ──────────────────────────────────

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            UIContextMenuConfiguration(
                identifier: nil,
                previewProvider: { [previewBuilder] in
                    let preview = UIHostingController(rootView: previewBuilder())
                    preview.view.backgroundColor = .clear
                    // UIKit caches `preferredContentSize` for the
                    // lift animation — without an explicit value
                    // it falls back to the host view's compressed
                    // frame, squashing the SwiftUI card. The size
                    // here matches the `.frame(width: 240)` declared
                    // inside `NoteCardPreview` so the lift renders
                    // at the SwiftUI-declared dimensions.
                    let target = preview.sizeThatFits(in: CGSize(width: 240, height: 600))
                    preview.preferredContentSize = target
                    return preview
                },
                actionProvider: { [menuBuilder] _ in
                    menuBuilder()
                }
            )
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionCommitAnimating
        ) {
            animator.addCompletion { [onTapPreview] in
                onTapPreview()
            }
        }
    }
}
