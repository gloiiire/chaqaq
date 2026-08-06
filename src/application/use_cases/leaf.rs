use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::domain::editor::EditorState;
use crate::domain::leaf::{Block, BlockContent, InlineText, Leaf, LeafMeta};
use crate::domain::parser::parse_inline;
use uuid::Uuid;

/// Creates a new leaf with a parsed inline title and persists it.
pub fn create_leaf(uow: &dyn UnitOfWork, title: &str) -> Result<Leaf, PinkhaError> {
    let doc = Leaf::new(parse_inline(title));
    uow.leaves().save(&doc)?;
    Ok(doc)
}

/// Variant of `create_leaf` that pins the doc's `created_at` to a
/// specific timestamp (RFC 3339). Used by importers (Notion / Bear /
/// Craft) so the imported note carries the original platform's
/// creation date through to its SQLite row — `created_at` is otherwise
/// set to `now()` at first INSERT and immutable afterwards.
pub fn create_leaf_with_created_at(
    uow: &dyn UnitOfWork,
    title: &str,
    created_at: String,
) -> Result<Leaf, PinkhaError> {
    let mut doc = Leaf::new(parse_inline(title));
    doc.created_at = Some(created_at);
    uow.leaves().save(&doc)?;
    Ok(doc)
}

/// Loads a full leaf by ID.
pub fn get_leaf(uow: &dyn UnitOfWork, id: Uuid) -> Result<Leaf, PinkhaError> {
    uow.leaves().load(id)
}

/// Returns lightweight metadata for all leaves (no blocks loaded).
pub fn list_leaves(uow: &dyn UnitOfWork) -> Result<Vec<LeafMeta>, PinkhaError> {
    uow.leaves().list()
}

/// Returns lightweight metadata for a single leaf. Callers that only
/// need the title / icon / cover should prefer this over [`get_leaf`]
/// so the block tree never crosses the boundary.
pub fn get_leaf_meta(uow: &dyn UnitOfWork, id: Uuid) -> Result<LeafMeta, PinkhaError> {
    // Column projection, not `load()` + `From<&Leaf>`. The latter loads the
    // whole block tree this function exists to avoid, and cannot populate
    // `updated_at` / `created_at` (they live only on the row), so it used to
    // hand back empty timestamps that disagreed with `list_leaves()`.
    uow.leaves().load_meta(id)
}

/// Soft-deletes a leaf by ID — recoverable via [`restore_leaf`].
pub fn delete_leaf(uow: &dyn UnitOfWork, leaf_id: Uuid) -> Result<(), PinkhaError> {
    uow.leaves().delete(leaf_id)
}

/// Lists soft-deleted leaves (newest-deleted first) — what the trash UI shows.
pub fn list_deleted_leaves(uow: &dyn UnitOfWork) -> Result<Vec<LeafMeta>, PinkhaError> {
    uow.leaves().list_deleted()
}

/// Restores a soft-deleted leaf (clears its `deleted_at`).
pub fn restore_leaf(uow: &dyn UnitOfWork, leaf_id: Uuid) -> Result<(), PinkhaError> {
    uow.leaves().restore(leaf_id)
}

/// Permanently deletes a soft-deleted leaf (hard delete).
pub fn purge_leaf(uow: &dyn UnitOfWork, leaf_id: Uuid) -> Result<(), PinkhaError> {
    uow.leaves().purge(leaf_id)
}

/// Updates the leaf title (parsed as inline rich text) and persists.
pub fn update_leaf_title(
    uow: &dyn UnitOfWork,
    leaf_id: Uuid,
    new_title: &str,
) -> Result<(), PinkhaError> {
    let repo = uow.leaves();
    let mut doc = repo.load(leaf_id)?;
    doc.title = parse_inline(new_title);
    repo.save(&doc)
}

/// Updates the leaf cover and persists.
pub fn update_leaf_cover(
    uow: &dyn UnitOfWork,
    leaf_id: Uuid,
    cover: Option<String>,
) -> Result<(), PinkhaError> {
    let repo = uow.leaves();
    let mut doc = repo.load(leaf_id)?;
    doc.cover = cover;
    repo.save(&doc)
}

/// Updates the leaf icon (small visual identifier — emoji or image URL/
/// filename) and persists.
pub fn update_leaf_icon(
    uow: &dyn UnitOfWork,
    leaf_id: Uuid,
    icon: Option<String>,
) -> Result<(), PinkhaError> {
    let repo = uow.leaves();
    let mut doc = repo.load(leaf_id)?;
    doc.icon = icon;
    repo.save(&doc)
}

/// Sets (or clears with `None`) the per-leaf accent color name
/// and persists. When `Some`, the editor renders its chrome with this
/// color instead of the app-wide accent from settings; `None` falls
/// back to the global accent.
pub fn update_leaf_accent_color(
    uow: &dyn UnitOfWork,
    leaf_id: Uuid,
    accent_color: Option<String>,
) -> Result<(), PinkhaError> {
    let repo = uow.leaves();
    let mut doc = repo.load(leaf_id)?;
    doc.accent_color = accent_color;
    repo.save(&doc)
}

/// Sets (or clears with `None`) the per-leaf writing direction.
/// Values: `"ltr"`, `"rtl"`, or `None` to let the system locale
/// decide. Acts as the default direction for every block; individual
/// blocks can still override via `set_block_text_direction`.
pub fn update_leaf_text_direction(
    uow: &dyn UnitOfWork,
    leaf_id: Uuid,
    text_direction: Option<String>,
) -> Result<(), PinkhaError> {
    let repo = uow.leaves();
    let mut doc = repo.load(leaf_id)?;
    doc.text_direction = text_direction;
    repo.save(&doc)
}

/// Sets (or clears with `None`) the per-leaf theme.
/// Values: `"original"`, `"tranquille"`, `"papier"`, `"gras"`,
/// `"calme"`, `"attention"`, or `None` to inherit from
/// `AppSettings.theme`. The editor maps the name to a palette
/// (background, text color, bold) at render time.
pub fn update_leaf_theme(
    uow: &dyn UnitOfWork,
    leaf_id: Uuid,
    theme: Option<String>,
) -> Result<(), PinkhaError> {
    let repo = uow.leaves();
    let mut doc = repo.load(leaf_id)?;
    doc.theme = theme;
    repo.save(&doc)
}

/// Replaces the leaf's reader-settings bundle (font scale, font
/// family, bold, line/letter/word spacing, margin scale, justify,
/// dark variant, custom-layout flag). Pass `None` to clear and
/// fall back to the theme's factory defaults. Mirrors Apple Books'
/// per-theme typography ; see `domain::leaf::ReaderSettings` and
/// `utilities/docs/BOOKS-READER-SETTINGS-RE.md`.
pub fn update_leaf_reader_settings(
    uow: &dyn UnitOfWork,
    leaf_id: Uuid,
    settings: Option<crate::domain::leaf::ReaderSettings>,
) -> Result<(), PinkhaError> {
    let repo = uow.leaves();
    let mut doc = repo.load(leaf_id)?;
    doc.reader_settings = settings;
    repo.save(&doc)
}

/// Toggles the read-only lock on a leaf and persists. Imports default
/// new leaves to `locked = true` so the user reads the extracted content
/// before editing it.
pub fn update_leaf_locked(
    uow: &dyn UnitOfWork,
    leaf_id: Uuid,
    locked: bool,
) -> Result<(), PinkhaError> {
    let repo = uow.leaves();
    let mut doc = repo.load(leaf_id)?;
    doc.locked = locked;
    repo.save(&doc)
}

/// Overrides the leaf's user-editable `published_at` timestamp.
/// Empty string resets the doc to the default "follow `created_at`"
/// behaviour. Mirrors `update_entry_published_at` on Entry.
pub fn update_leaf_published_at(
    uow: &dyn UnitOfWork,
    leaf_id: Uuid,
    new_published_at: String,
) -> Result<(), PinkhaError> {
    let repo = uow.leaves();
    let mut doc = repo.load(leaf_id)?;
    doc.published_at = new_published_at;
    repo.save(&doc)
}

/// Moves a leaf to a shelf (or to the root when `shelf_id` is `None`).
pub fn move_leaf_to_shelf(
    uow: &dyn UnitOfWork,
    leaf_id: Uuid,
    shelf_id: Option<Uuid>,
) -> Result<(), PinkhaError> {
    uow.leaves().move_to_shelf(leaf_id, shelf_id)
}

/// Pins or unpins a leaf. Pinning surfaces the leaf in the dedicated
/// PINNED section above SHELVES in the library home view ;
/// unpinning removes it.
pub fn set_leaf_pinned(
    uow: &dyn UnitOfWork,
    leaf_id: Uuid,
    pinned: bool,
) -> Result<(), PinkhaError> {
    uow.leaves().set_pinned(leaf_id, pinned)
}

/// Bulk-rewrites the manual sort index for `ordered_ids`. The first id
/// gets index 0, the second gets 1, etc. Wires the SwiftUI
/// `.onMove(perform:)` reorder into persistence.
pub fn set_leaves_manual_order(
    uow: &dyn UnitOfWork,
    ordered_ids: &[Uuid],
) -> Result<(), PinkhaError> {
    uow.leaves().set_manual_order(ordered_ids)
}

/// Returns lightweight metadata for all leaves in the given shelf (or root).
pub fn list_leaves_in_shelf(
    uow: &dyn UnitOfWork,
    shelf_id: Option<Uuid>,
) -> Result<Vec<LeafMeta>, PinkhaError> {
    uow.leaves().list_by_shelf(shelf_id)
}

/// Sets the parent leaf for Notion-style page-in-page hierarchy. Pass
/// `None` to promote `leaf_id` back to root. Rejects cycles (refuses to make
/// `leaf_id` a descendant of itself) so the hierarchy stays acyclic — without
/// this, the breadcrumbs would loop and a depth-first render would recurse
/// forever.
pub fn update_leaf_parent(
    uow: &dyn UnitOfWork,
    leaf_id: Uuid,
    new_parent_leaf_id: Option<Uuid>,
) -> Result<(), PinkhaError> {
    if let Some(new_parent) = new_parent_leaf_id {
        if new_parent == leaf_id {
            return Err(PinkhaError::InvalidOperation(
                "a leaf cannot be its own parent".into(),
            ));
        }
        // Walk up from the prospective new parent: if we ever reach `leaf_id`,
        // the move would create a cycle.
        let repo = uow.leaves();
        let mut cursor = Some(new_parent);
        while let Some(id) = cursor {
            let ancestor = repo.load(id)?;
            if ancestor.parent_leaf_id == Some(leaf_id) {
                return Err(PinkhaError::InvalidOperation(
                    "moving here would create a parent/child cycle".into(),
                ));
            }
            cursor = ancestor.parent_leaf_id;
        }
    }
    let repo = uow.leaves();
    let mut doc = repo.load(leaf_id)?;
    doc.parent_leaf_id = new_parent_leaf_id;
    repo.save(&doc)
}

/// Returns lightweight metadata for leaves at the root of the library —
/// neither nested inside another leaf nor filed into an *active* shelf.
/// Drives the home view's "All" section, which only surfaces leaves that
/// haven't been parented. Filing a leaf in a shelf must remove it from the
/// root listing, otherwise the user sees the same leaf in two places and
/// reads the move as a copy.
///
/// Root-ness is delegated to `list_by_shelf(None)` rather than re-tested
/// here as `shelf_id.is_none()`. Those two are not the same predicate: a
/// leaf can point at a shelf that has since been discarded to Compost, and
/// `ShelfRepository::delete` deliberately leaves `shelf_id` intact so
/// restoring the shelf brings its subtree back. Testing `shelf_id.is_none()`
/// therefore filed those leaves under a shelf the user can no longer see,
/// erasing them from the library while they were never deleted. The SQL
/// predicate already treated a trashed shelf as no shelf; this path was
/// simply not using it.
pub fn list_root_leaves(uow: &dyn UnitOfWork) -> Result<Vec<LeafMeta>, PinkhaError> {
    Ok(uow
        .leaves()
        .list_by_shelf(None)?
        .into_iter()
        .filter(|m| m.parent_leaf_id.is_none())
        .collect())
}

/// Returns lightweight metadata for the direct children of `parent_leaf_id`.
/// Used by the breadcrumbs / child-page section of the leaf view.
pub fn list_child_leaves(
    uow: &dyn UnitOfWork,
    parent_leaf_id: Uuid,
) -> Result<Vec<LeafMeta>, PinkhaError> {
    Ok(uow
        .leaves()
        .list()?
        .into_iter()
        .filter(|m| m.parent_leaf_id == Some(parent_leaf_id))
        .collect())
}

/// Applies the editor state to a text-bearing block and persists the leaf.
///
/// Returns `InvalidOperation` when the target block does not carry editable text
/// (e.g. `Divider`, `Book`).
pub fn save_edited_block(
    uow: &dyn UnitOfWork,
    leaf_id: Uuid,
    block_id: Uuid,
    editor_state: &EditorState,
) -> Result<(), PinkhaError> {
    let repo = uow.leaves();
    let mut doc = repo.load(leaf_id)?;
    let inlines: Vec<InlineText> = Vec::from(&editor_state.text);
    let block = find_block_mut(&mut doc.blocks, block_id).ok_or(PinkhaError::NotFound(block_id))?;

    block.content = match &block.content {
        BlockContent::Text(_) => BlockContent::Text(inlines),
        BlockContent::Heading { level, .. } => BlockContent::Heading {
            text: inlines,
            level: *level,
        },
        BlockContent::Quote { icon, .. } => BlockContent::Quote {
            icon: icon.clone(),
            text: inlines,
        },
        BlockContent::Todo { done, .. } => BlockContent::Todo {
            text: inlines,
            done: *done,
        },
        _ => {
            return Err(PinkhaError::InvalidOperation(format!(
                "block {block_id} does not contain editable text"
            )));
        }
    };
    repo.save(&doc)
}

// ── Internal tree helpers (shared with blocks module) ─────────────────────────

pub(super) fn find_block_mut(blocks: &mut [Block], id: Uuid) -> Option<&mut Block> {
    // first pass: search at the current level
    if let Some(pos) = blocks.iter().position(|b| b.id == id) {
        return Some(&mut blocks[pos]);
    }
    // second pass: recurse into children
    for block in blocks.iter_mut() {
        if let Some(found) = find_block_mut(&mut block.children, id) {
            return Some(found);
        }
    }
    None
}
