import SwiftUI
import PinkhaFFI
import PinkhaCore
import PinkhaDesignSystem
import BookFeature

// ── Recent strip ──────────────────────────────────────────────────────────────

/// Horizontal scroll strip displaying the most recently updated library items.
public struct RecentStrip: View {
    let items: [WorkspaceItem]
    let api: PinkhaApi?
    /// Geometry namespace for the doc-open zoom transition. Each
    /// note card tags itself with `.matchedTransitionSource(...)` so
    /// SwiftUI knows where the destination view should fly out of.
    let zoomNamespace: Namespace.ID
    let onDisappear: () -> Void
    /// Programmatic-push handler for note items — wired from the
    /// parent so each card can use a `Button` instead of
    /// `NavigationLink`. iOS 26 has a confirmed bug where multiple
    /// `NavigationLink + .contextMenu` rows inside a horizontal
    /// `ScrollView` only register the long-press on the first row.
    let onOpenNote: (String) -> Void
    var onRenameNote: ((LeafMetaFfi) -> Void)? = nil
    var onDeleteNote: ((LeafMetaFfi) -> Void)? = nil
    /// Optional handler for "Add to a book" — when nil the menu
    /// item is hidden (e.g. when no DB exists yet).
    var onAddToBook: ((LeafMetaFfi) -> Void)? = nil

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    if let api {
                        switch item {
                        case .note(let doc):
                            RecentNoteCard(
                                item: item,
                                doc: doc,
                                onOpen: { onOpenNote(doc.id) },
                                onRename: { onRenameNote?(doc) },
                                onDelete: { onDeleteNote?(doc) },
                                onAddToBook: onAddToBook.map { handler in
                                    { handler(doc) }
                                }
                            )
                            .matchedTransitionSource(id: doc.id, in: zoomNamespace)
                            .id(doc.id)
                        case .book(let db):
                            NavigationLink(destination:
                                BookView(bookId: db.id, api: api,
                                             onDisappear: onDisappear)
                                    .navigationTransition(
                                        .zoom(sourceID: db.id, in: zoomNamespace))
                            ) {
                                RecentCard(item: item)
                            }
                            .buttonStyle(.plain)
                            // Pair with the destination's
                            // `.navigationTransition(.zoom(sourceID:in:))`
                            // so opening a DB from the strip flies
                            // out of the card, same vocabulary as
                            // notes.
                            .matchedTransitionSource(id: db.id, in: zoomNamespace)
                            .id(db.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
    }
}

/// Per-item wrapper so each card owns an independent `Button` +
/// `.contextMenu` registration. Pulling this out of `RecentStrip`'s
/// body fixed the "long-press lifts the whole strip as one" bug on
/// iOS 26 — SwiftUI registers the gesture recogniser per dedicated
/// View struct, not per `ForEach` iteration of an inline expression.
private struct RecentNoteCard: View {
    let item: WorkspaceItem
    let doc: LeafMetaFfi
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    /// When non-nil, surfaces the "Add to a book" entry between
    /// Rename and Delete in the context menu.
    var onAddToBook: (() -> Void)? = nil

    public var body: some View {
        // UIKit-backed context menu — SwiftUI's `.contextMenu` has a
        // confirmed iOS 26 bug inside horizontal `ScrollView` where
        // it only registers on the first row. UIKit's
        // `UIContextMenuInteraction` (which Apple Music uses for the
        // same UX) doesn't have that quirk.
        UIKitContextMenu(
            content: { RecentCard(item: item) },
            preview: { NoteCardPreview(doc: doc) },
            menu: {
                let rename = UIAction(
                    title: "Rename",
                    image: UIImage(systemName: "pencil"),
                    handler: { _ in onRename() }
                )
                let delete = UIAction(
                    title: "Delete",
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive,
                    handler: { _ in onDelete() }
                )
                var children: [UIMenuElement] = [rename]
                if let onAddToBook {
                    children.append(UIAction(
                        title: "Add to a book",
                        image: UIImage(systemName: "tablecells.badge.ellipsis"),
                        handler: { _ in onAddToBook() }
                    ))
                }
                children.append(delete)
                return UIMenu(children: children)
            },
            onTapPreview: onOpen
        )
        .frame(width: 165, height: 170)
        .onTapGesture {
            Haptic.tap()
            onOpen()
        }
    }
}

/// A card in the recent strip — Notion-style with a cover image
/// (or fallback gradient) filling the top half, an icon overlapping the
/// cover/content boundary, and the title plus relative date below.
public struct RecentCard: View {
    let item: WorkspaceItem

    private let cornerRadius: CGFloat = 16
    private let coverHeight: CGFloat = 80
    private let iconSize: CGFloat = 32

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverImageView(cover: coverValue)
                .frame(height: coverHeight)
                .clipped()
            // The bottom block hosts both the overlapping icon and the
            // title/date stack. The icon is placed in an overlay so it
            // can sit half on top of the cover and half on the white
            // surface below — same trick Notion uses.
            VStack(alignment: .leading, spacing: 3) {
                Text(item.titlePlain.isEmpty ? "Untitled" : item.titlePlain)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let date = formattedRelativeDate(item.updatedAt) {
                    Text(date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            // The padding top makes room for the icon that will overlap
            // from above via the overlay below.
            .padding(.top, iconSize / 2 + 6)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                itemIcon
                    .frame(width: iconSize, height: iconSize)
                    .padding(.leading, 10)
                    .offset(y: -iconSize / 2)
            }
        }
        .frame(width: 165, height: 170, alignment: .leading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var coverValue: String? {
        switch item {
        case .note(let doc):    return doc.cover
        case .book(let db): return db.cover
        }
    }

    @ViewBuilder
    private var itemIcon: some View {
        switch item {
        case .note(let doc):
            if let icon = doc.icon, !icon.isEmpty {
                Text(icon).font(.title2)
            } else {
                Image(systemName: "doc.text")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: iconSize, height: iconSize)
                    .background(Color(.systemBackground), in: Circle())
                    .overlay(Circle().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            }
        case .book(let db):
            if let icon = db.icon, !icon.isEmpty {
                Text(icon).font(.title2)
            } else {
                Image(systemName: "tablecells")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: iconSize, height: iconSize)
                    .background(Color(.systemBackground), in: Circle())
                    .overlay(Circle().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            }
        }
    }
}

// ── Long-press preview card ───────────────────────────────────────────────────

/// Apple-Music-style floating card shown when the user long-presses
/// a note row. Larger, more deliberate than the list row — the title
/// reads loud, the icon anchors the eye. Sits over a frosted
/// background while the contextMenu's actions slide up underneath.
public struct NoteCardPreview: View {
    let doc: LeafMetaFfi

    private let iconSize: CGFloat = 44

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover image (or fallback gradient) on top, exactly
            // like the RecentCard pattern — Notion-style framing.
            CoverImageView(cover: doc.cover)
                .frame(height: 140)
                .clipped()

            VStack(alignment: .leading, spacing: 6) {
                Text(doc.titlePlain.isEmpty ? "Untitled" : doc.titlePlain)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let date = formattedRelativeDate(doc.updatedAt) {
                    Text(date)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.top, iconSize / 2 + 10)
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                // Icon overlapping the cover/content boundary,
                // matching the RecentCard treatment.
                Group {
                    if let icon = doc.icon, !icon.isEmpty {
                        Text(icon).font(.system(size: 30))
                    } else {
                        Image(systemName: "doc.text")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: iconSize, height: iconSize)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
                .padding(.leading, 16)
                .offset(y: -iconSize / 2)
            }
        }
        .frame(width: 240)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
}
