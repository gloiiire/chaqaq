import UIKit

// ── Mention bar ────────────────────────────────────────────────────────────────
//
// Floating glass capsule that hovers right above the keyboard pill while
// the user is composing a `@`-mention. Shows a horizontal scroll of
// leaf chips that filter live as the user types more letters after
// the `@`. Tapping a chip lets the parent coordinator insert the picked
// leaf as a `pinkha://doc/{id}` link.
//
// Lives as a subview of the editor's window so it isn't clipped by the
// `inputAccessoryView` slot — its frame tracks the keyboard's top edge
// via `UIView.keyboardLayoutGuide` (iOS 15+).

/// One row in the mention bar. Mirrors `MentionCandidate` plus the chip
/// view rendering — kept separate so the parent doesn't need to know
/// about UIKit details.
final class MentionBar: UIView {

    /// Notified on chip tap with the picked candidate's id.
    var onPick: ((MentionCandidate) -> Void)?

    /// The pill (visual scaffold) and scroll view that holds the chips.
    private let pill = UIView()
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let scroll = UIScrollView()
    /// Chips currently laid out. Recomputed every time the candidate
    /// list changes (filter narrows / widens).
    private var chips: [UIButton] = []

    private let pillH: CGFloat = 44
    private let margeH: CGFloat = 12
    private let chipHeight: CGFloat = 32
    private let chipPaddingH: CGFloat = 12
    private let chipGap: CGFloat = 6

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth]

        pill.backgroundColor = .clear
        pill.layer.cornerRadius = pillH / 2
        pill.layer.masksToBounds = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)

        glass.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(glass)

        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(scroll)

        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margeH),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margeH),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.heightAnchor.constraint(equalToConstant: pillH),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            glass.topAnchor.constraint(equalTo: pill.topAnchor),
            glass.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: pill.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Lays out one button per candidate. Cheap enough to call on every
    /// keystroke while the user filters — chips are simple buttons,
    /// auto-layout reuse isn't worth the complexity.
    func setCandidates(_ candidates: [MentionCandidate]) {
        chips.forEach { $0.removeFromSuperview() }
        chips.removeAll()
        var x: CGFloat = 0
        let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        for candidate in candidates {
            let btn = UIButton(type: .system)
            btn.setTitle(candidate.title, for: .normal)
            btn.setTitleColor(.label, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            btn.setImage(UIImage(systemName: "doc.text", withConfiguration: cfg), for: .normal)
            btn.tintColor = .secondaryLabel
            btn.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
            btn.contentEdgeInsets = UIEdgeInsets(
                top: 0, left: chipPaddingH,
                bottom: 0, right: chipPaddingH)
            btn.layer.cornerRadius = chipHeight / 2
            btn.layer.masksToBounds = true
            btn.backgroundColor = UIColor.tertiarySystemFill
            let width = max(chipHeight,
                            btn.intrinsicContentSize.width + chipPaddingH)
            btn.frame = CGRect(x: x, y: (pillH - chipHeight) / 2,
                               width: width, height: chipHeight)
            let id = candidate.id
            let title = candidate.title
            btn.addAction(UIAction { [weak self] _ in
                self?.onPick?(MentionCandidate(id: id, title: title))
            }, for: .touchUpInside)
            scroll.addSubview(btn)
            chips.append(btn)
            x += width + chipGap
        }
        scroll.contentSize = CGSize(width: x, height: pillH)
        scroll.setContentOffset(.zero, animated: false)
    }
}
