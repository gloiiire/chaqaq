import SwiftUI
import PinkhaRichText

// ── Tappable empty state ──────────────────────────────────────────────────────

/// Placeholder shown when the leaf has no blocks yet. A tap creates the first block.
public struct EmptyEditorState: View {
    let onBegin: () -> Void
    @State private var focused = false

    public var body: some View {
        RichTextEditor(
            spans: .constant([]),
            isFocused: $focused,
            placeholder: String(localized: "Start writing…"),
            onSave: nil,
            onNewBlock: nil,
            onDeleteBloc: nil,
            onConvert: nil
        )
        .onChange(of: focused) { _, isFocused in
            if isFocused { onBegin() }
        }
    }
}

// ── Add block button ──────────────────────────────────────────────────────────

/// List footer button that opens the block picker sheet.
public struct AddBlockButton: View {
    let action: () -> Void
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                Text("New block")
            }
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

// ── Undo / Redo ───────────────────────────────────────────────────────────────
// A single glass capsule background for both icons — same as the lock/reorder pill
// in the nav bar: one glass capsule, each icon independently tappable.

/// Glass capsule pill with undo and redo buttons. Shown at the bottom-left when the keyboard is hidden.
public struct UndoRedoPill: View {
    let canUndo: Bool
    let canRedo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void

    public var body: some View {
        HStack(spacing: 0) {
            iconButton(icon: "arrow.uturn.backward", enabled: canUndo, action: onUndo)
            iconButton(icon: "arrow.uturn.forward",  enabled: canRedo, action: onRedo)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: canUndo)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: canRedo)
    }

    private func iconButton(icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.45))
                .frame(width: 54, height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// ── Block type picker sheet ───────────────────────────────────────────────────

/// Sheet listing all available block types for insertion.
public struct BlockPickerSheet: View {
    let onSelect: (NewBlockType) -> Void
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            List(NewBlockType.allCases) { type in
                Button {
                    onSelect(type)
                    dismiss()
                } label: {
                    Label(type.displayName, systemImage: type.icone)
                        .foregroundStyle(.primary)
                }
            }
            .navigationTitle("Add a block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(.primary)
                        .accessibilityLabel("Cancel")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// ── iOS 27 reorder container bridge ───────────────────────────────────────
//
// `.reorderContainer(for:move:)` requires iOS 27 and takes a closure whose
// parameter type (`ReorderDifference`) is also iOS 27-only, so the whole
// call site must live inside an `if #available(iOS 27.0, *)`. Wrapping it
// in a ViewModifier keeps the `documentList` modifier chain flat.

struct BlockReorderContainerModifier: ViewModifier {
    let vm: LeafViewModel
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.reorderContainer(for: EditableBlock.self) { diff in
                vm.moveBlocks(applyingDifference: diff)
            }
        } else {
            content
        }
    }
}

/// Applies `.toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)`
/// on iOS 27+ when active — the nav bar minimises as the user scrolls a
/// long leaf and restores on reverse scroll (Safari/Books style). Pass
/// `active: false` (reader mode) to skip minimisation entirely. iOS 26
/// falls back to the fixed bar (no-op).
struct LeafNavBarMinimizationModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active, #available(iOS 27.0, *) {
            content
                .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
                // Coupe l'aller d'une boucle de mise en page qui gelait l'app
                // au changement d'onglet depuis une note.
                //
                // Par defaut, la zone sure suit la barre pendant qu'elle se
                // retracte, pour que le contenu occupe la place liberee.
                // Mais changer la zone sure d'un `ScrollView` declenche
                // `_notifyDidScroll`, que l'observateur de defilement de la
                // barre ecoute pour decider de sa hauteur — laquelle
                // redefinit la zone sure. Un cycle.
                //
                // Hors transition il s'amortit : chaque tour attend l'image
                // suivante. En tapant un onglet, la mise en page est
                // SYNCHRONE (`layoutBelowIfNeeded` sous
                // `performWithoutAnimation`), plus aucune frontiere d'image,
                // et le cycle tourne sur place a 100 % de CPU. Profil d'un
                // gel reel : `_updateSafeAreaInsets` ->
                // `UIScrollView.setSafeAreaInsets:` -> `_notifyDidScroll` ->
                // `UINavigationController _observeScrollViewDidScroll:topLayoutType:`
                // -> `_edgeInsetsForChildViewController:` -> et on recommence.
                // Bisection utilisateur : retirer la minimisation supprime le
                // gel, la remettre le ramene.
                //
                // `.disabled` fige la zone sure pendant la retraction. La
                // barre se retracte toujours — le reglage d'accessibilite est
                // preserve — mais le contenu ne reflue plus dans sa place,
                // donc plus rien ne reboucle. Apple documente ce cas comme
                // « utile quand le contenu passe sous la barre » : c'est
                // exactement une note a couverture, qui pose deja
                // `.ignoresSafeArea(.top)`.
                .toolbarMinimizationSafeAreaAdjustment(.disabled, for: .navigationBar)
        } else {
            content
        }
    }
}

/// Applies SwiftUI 27's `.navigationTransition(.crossFade)` — a soft
/// Books-style fade for mention-link navigation. iOS 26 keeps the
/// default push (no-op).
struct MentionLinkCrossFadeModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.navigationTransition(.crossFade)
        } else {
            content
        }
    }
}


// ── Bascule du titre vers la barre de navigation ──────────────────────────

/// Décide si le titre doit s'afficher dans la barre de navigation, à
/// partir du décalage de défilement et de l'état courant.
///
/// Fonction libre, donc testable sans monter une vue — même parti pris que
/// `markdownShortcut(for:)`.
///
/// La zone morte 40–60 pt n'est pas cosmétique. La grandeur mesurée par
/// `onScrollGeometryChange` vaut `contentOffset.y + contentInsets.top`, et
/// la réaction modifie précisément cet inset (titre dans la barre, plus la
/// minimisation de la barre qui la redimensionne). Avec un seuil unique,
/// se garer dessus fait osciller le drapeau : chaque bascule déplace
/// l'inset, donc la mesure, donc rebascule. Hors transition ça s'amortit,
/// chaque bascule attendant l'image suivante ; pendant une transition
/// d'onglet, la mise en page est SYNCHRONE (`layoutBelowIfNeeded` dans
/// `performWithoutAnimation`) et la boucle tourne sur place.
public func titleShouldEnterNavBar(offset: CGFloat, currently: Bool) -> Bool {
    currently ? offset > 40 : offset > 60
}
