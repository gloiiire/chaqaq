//! Leaf, block and search operations on the [`PinkhaApi`] facade.

use crate::application::use_cases;
use crate::domain::leaf::BlockContent;

use super::types::{
    BlockSearchHitFfi, BookMetaFfi, LeafMetaFfi, ShelfMetaFfi, book_meta_to_ffi, leaf_meta_to_ffi,
    shelf_meta_to_ffi,
};
use super::validation::{get_block_id, parse_json, parse_uuid, parse_uuids, validate_string};
use super::{PinkhaApi, PinkhaError};

impl PinkhaApi {
    // ── Leaves ─────────────────────────────────────────────

    /// Creates a new leaf with the given plain-text title.
    /// Returns the UUID string of the created leaf.
    pub fn create_leaf(&self, title: String) -> Result<String, PinkhaError> {
        validate_string(&title, "title")?;
        let doc = use_cases::create_leaf(&self.uow(), &title).map_err(PinkhaError::from)?;
        Ok(doc.id.to_string())
    }

    /// Returns the full leaf as a JSON string (decodable as `LeafFfi` in Swift).
    pub fn get_leaf_json(&self, id: String) -> Result<String, PinkhaError> {
        let uuid = parse_uuid(&id)?;
        let doc = use_cases::get_leaf(&self.uow(), uuid).map_err(PinkhaError::from)?;
        serde_json::to_string(&doc).map_err(|e| PinkhaError::Storage {
            detail: e.to_string(),
        })
    }

    /// Returns lightweight metadata for all non-deleted leaves.
    pub fn list_leaves(&self) -> Result<Vec<LeafMetaFfi>, PinkhaError> {
        let metas = use_cases::list_leaves(&self.uow()).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(leaf_meta_to_ffi).collect())
    }

    /// Soft-deletes the leaf identified by `id`.
    pub fn delete_leaf(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        use_cases::delete_leaf(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Soft-deletes every leaf. Returns the number of leaves deleted.
    pub fn delete_all_leaves(&self) -> Result<u32, PinkhaError> {
        let metas = use_cases::list_leaves(&self.uow()).map_err(PinkhaError::from)?;
        let count = metas.len() as u32;
        for meta in metas {
            use_cases::delete_leaf(&self.uow(), meta.id).map_err(PinkhaError::from)?;
        }
        Ok(count)
    }

    /// Replaces the leaf title with a plain-text string parsed into inline spans.
    pub fn update_leaf_title(&self, id: String, new_title: String) -> Result<(), PinkhaError> {
        validate_string(&new_title, "new_title")?;
        let uuid = parse_uuid(&id)?;
        use_cases::update_leaf_title(&self.uow(), uuid, &new_title).map_err(PinkhaError::from)
    }

    /// Sets or clears the cover of a leaf.
    pub fn update_leaf_cover(&self, id: String, cover: Option<String>) -> Result<(), PinkhaError> {
        if let Some(c) = cover.as_deref() {
            validate_string(c, "cover")?;
        }
        let uuid = parse_uuid(&id)?;
        use_cases::update_leaf_cover(&self.uow(), uuid, cover).map_err(PinkhaError::from)
    }

    /// Sets or clears the page icon. Accepts an emoji, a local cover-dir
    /// filename, or a remote URL — the renderer picks the right strategy.
    pub fn update_leaf_icon(&self, id: String, icon: Option<String>) -> Result<(), PinkhaError> {
        if let Some(i) = icon.as_deref() {
            validate_string(i, "icon")?;
        }
        let uuid = parse_uuid(&id)?;
        use_cases::update_leaf_icon(&self.uow(), uuid, icon).map_err(PinkhaError::from)
    }

    /// Sets (or clears with `None`) the per-leaf accent color name
    /// (e.g. `"red"`, `"teal"`). Same naming scheme as `set_block_color`.
    /// When set, the editor renders its chrome in this color instead
    /// of the app-wide accent; `None` falls back to the global accent.
    pub fn update_leaf_accent_color(
        &self,
        id: String,
        accent_color: Option<String>,
    ) -> Result<(), PinkhaError> {
        if let Some(c) = accent_color.as_deref() {
            validate_string(c, "accent_color")?;
        }
        let uuid = parse_uuid(&id)?;
        use_cases::update_leaf_accent_color(&self.uow(), uuid, accent_color)
            .map_err(PinkhaError::from)
    }

    /// Sets the read-only lock on a leaf. Used by the editor toggle and
    /// auto-applied by data-extract imports (Notion/Bear/Craft) which lock
    /// new leaves by default — the user reads first, unlocks before
    /// editing imported content.
    pub fn update_leaf_locked(&self, id: String, locked: bool) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        use_cases::update_leaf_locked(&self.uow(), uuid, locked).map_err(PinkhaError::from)
    }

    /// Overrides the leaf's user-editable `published_at`.
    /// Empty string resets it to the default "follow `created_at`"
    /// behaviour. Mirrors `update_entry_published_at` on Entry.
    pub fn update_leaf_published_at(
        &self,
        id: String,
        new_published_at: String,
    ) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        if new_published_at.len() > 64 {
            return Err(PinkhaError::InvalidOperation {
                detail: "published_at too long".to_string(),
            });
        }
        use_cases::update_leaf_published_at(&self.uow(), uuid, new_published_at)
            .map_err(PinkhaError::from)
    }

    /// Pins or unpins a leaf. The home view's PINNED section surfaces
    /// pinned leaves at the top, sorted by `pinned_at` desc.
    pub fn set_leaf_pinned(&self, id: String, pinned: bool) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        use_cases::set_leaf_pinned(&self.uow(), uuid, pinned).map_err(PinkhaError::from)
    }

    /// Bulk-rewrites the manual sort index : first id gets index 0,
    /// second gets 1, etc. Called from the drag-and-drop reorder UI.
    pub fn set_leaves_manual_order(&self, ordered_ids: Vec<String>) -> Result<(), PinkhaError> {
        let uuids = parse_uuids(ordered_ids)?;
        use_cases::set_leaves_manual_order(&self.uow(), &uuids).map_err(PinkhaError::from)
    }

    /// Re-inserts a whole block subtree at `index` under `parent_id`
    /// (`None` = top level), preserving its ids, attributes and children.
    ///
    /// Inverse of `delete_block`, which removes a block *and its subtree*.
    /// `add_block` can't undo that — it appends a bare `BlockContent` at the
    /// root, so nesting, colour, background colour and writing direction are
    /// all lost. Takes a full `Block` JSON rather than a `BlockContent`.
    pub fn insert_block_tree(
        &self,
        leaf_id: String,
        block_json: String,
        parent_id: Option<String>,
        index: u32,
    ) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&leaf_id)?;
        let parent = parent_id.as_deref().map(parse_uuid).transpose()?;
        let block: crate::domain::leaf::Block = parse_json(&block_json)?;
        use_cases::insert_block_tree(&self.uow(), uuid, block, parent, index as usize)
            .map_err(PinkhaError::from)
    }

    /// Appends a block to a leaf. `block_content_json` must be a JSON-encoded
    /// [`BlockContent`]. Returns the UUID string of the newly created block.
    pub fn add_block(
        &self,
        leaf_id: String,
        block_content_json: String,
    ) -> Result<String, PinkhaError> {
        let uuid = parse_uuid(&leaf_id)?;
        let content: BlockContent = parse_json(&block_content_json)?;
        let doc = use_cases::add_block(&self.uow(), uuid, content).map_err(PinkhaError::from)?;
        doc.blocks
            .last()
            .map(|b| b.id.to_string())
            .ok_or_else(|| PinkhaError::InvalidOperation {
                detail: "block not found after insertion".to_string(),
            })
    }

    /// Replaces the content of an existing block. `content_json` must be a
    /// JSON-encoded [`BlockContent`].
    pub fn update_block(
        &self,
        leaf_id: String,
        block_id: String,
        content_json: String,
    ) -> Result<(), PinkhaError> {
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        let content: BlockContent = parse_json(&content_json)?;
        use_cases::update_block(&self.uow(), leaf_uuid, block_uuid, content)
            .map_err(PinkhaError::from)
    }

    /// Sets the block-level *background* color, or clears it when `color`
    /// is `None`. Independent from [`set_block_color`] — colors a soft
    /// tinted band behind the whole block (highlight style).
    pub fn set_block_background_color(
        &self,
        leaf_id: String,
        block_id: String,
        background_color: Option<String>,
    ) -> Result<(), PinkhaError> {
        if let Some(c) = background_color.as_deref() {
            validate_string(c, "background_color")?;
        }
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        use_cases::set_block_background_color(&self.uow(), leaf_uuid, block_uuid, background_color)
            .map_err(PinkhaError::from)
    }

    /// Sets the per-block writing direction (`"ltr"` / `"rtl"`), or
    /// clears with `None` to inherit the leaf-level setting.
    pub fn set_block_text_direction(
        &self,
        leaf_id: String,
        block_id: String,
        text_direction: Option<String>,
    ) -> Result<(), PinkhaError> {
        if let Some(d) = text_direction.as_deref() {
            validate_string(d, "text_direction")?;
        }
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        use_cases::set_block_text_direction(&self.uow(), leaf_uuid, block_uuid, text_direction)
            .map_err(PinkhaError::from)
    }

    /// Sets the per-leaf writing direction (`"ltr"` / `"rtl"`), or
    /// clears with `None` to let the system locale decide. The chosen
    /// direction is the default for every block in the doc.
    pub fn update_leaf_text_direction(
        &self,
        id: String,
        text_direction: Option<String>,
    ) -> Result<(), PinkhaError> {
        if let Some(d) = text_direction.as_deref() {
            validate_string(d, "text_direction")?;
        }
        let uuid = parse_uuid(&id)?;
        use_cases::update_leaf_text_direction(&self.uow(), uuid, text_direction)
            .map_err(PinkhaError::from)
    }

    /// Sets the per-leaf theme name, or clears with `None` to
    /// inherit from `AppSettings.theme`.
    pub fn update_leaf_theme(&self, id: String, theme: Option<String>) -> Result<(), PinkhaError> {
        if let Some(t) = theme.as_deref() {
            validate_string(t, "theme")?;
        }
        let uuid = parse_uuid(&id)?;
        use_cases::update_leaf_theme(&self.uow(), uuid, theme).map_err(PinkhaError::from)
    }

    /// Sets the block-level text color, or clears it when `color` is `None`.
    ///
    /// Color is a color name like `"red"` / `"blue"` / `"green"` etc. — the
    /// rendering layer maps the name to a concrete value. Inline color styles
    /// on individual spans always override the block color.
    pub fn set_block_color(
        &self,
        leaf_id: String,
        block_id: String,
        color: Option<String>,
    ) -> Result<(), PinkhaError> {
        if let Some(c) = color.as_deref() {
            validate_string(c, "color")?;
        }
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        use_cases::set_block_color(&self.uow(), leaf_uuid, block_uuid, color)
            .map_err(PinkhaError::from)
    }

    /// Removes a block (and all its children) from a leaf.
    pub fn delete_block(&self, leaf_id: String, block_id: String) -> Result<(), PinkhaError> {
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        use_cases::delete_block(&self.uow(), leaf_uuid, block_uuid).map_err(PinkhaError::from)
    }

    /// Duplicates a block (and all its children, with fresh UUIDs) and
    /// inserts the clone right after the original at the same level.
    /// Returns the new top-level block id so the UI can focus / scroll
    /// to it.
    pub fn duplicate_block(
        &self,
        leaf_id: String,
        block_id: String,
    ) -> Result<String, PinkhaError> {
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        use_cases::duplicate_block(&self.uow(), leaf_uuid, block_uuid)
            .map(|id| id.to_string())
            .map_err(PinkhaError::from)
    }

    /// Reorders the root-level blocks of a leaf according to `order`.
    /// Blocks not mentioned in `order` are appended at the end.
    pub fn reorder_blocks(&self, leaf_id: String, order: Vec<String>) -> Result<(), PinkhaError> {
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let uuids = parse_uuids(order)?;
        use_cases::reorder_blocks(&self.uow(), leaf_uuid, uuids).map_err(PinkhaError::from)
    }

    /// Appends a child block under `parent_id`. Returns the new block UUID string.
    pub fn add_child_block(
        &self,
        leaf_id: String,
        parent_id: String,
        block_content_json: String,
    ) -> Result<String, PinkhaError> {
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let parent_uuid = parse_uuid(&parent_id)?;
        let content: BlockContent = parse_json(&block_content_json)?;
        use_cases::add_child_block(&self.uow(), leaf_uuid, parent_uuid, content)
            .map(get_block_id)
            .map_err(PinkhaError::from)
    }

    /// Reorders the children of `parent_id` according to `order`.
    pub fn reorder_child_blocks(
        &self,
        leaf_id: String,
        parent_id: String,
        order: Vec<String>,
    ) -> Result<(), PinkhaError> {
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let parent_uuid = parse_uuid(&parent_id)?;
        let uuids = parse_uuids(order)?;
        use_cases::reorder_child_blocks(&self.uow(), leaf_uuid, parent_uuid, uuids)
            .map_err(PinkhaError::from)
    }

    /// Moves a block to a new parent. Pass `None` for `new_parent_id` to move
    /// the block to the leaf root.
    pub fn move_block(
        &self,
        leaf_id: String,
        block_id: String,
        new_parent_id: Option<String>,
    ) -> Result<(), PinkhaError> {
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        let parent_uuid = new_parent_id.as_deref().map(parse_uuid).transpose()?;
        use_cases::move_block(&self.uow(), leaf_uuid, block_uuid, parent_uuid)
            .map_err(PinkhaError::from)
    }

    /// Indents a block — moves it under the previous sibling at the same
    /// level. Fails with `InvalidOperation` when the block is the first of
    /// its level (nothing to indent under).
    pub fn indent_block(&self, leaf_id: String, block_id: String) -> Result<(), PinkhaError> {
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        use_cases::indent_block(&self.uow(), leaf_uuid, block_uuid).map_err(PinkhaError::from)
    }

    /// Outdents a block — moves it out of its current parent up to the
    /// grandparent level, inserted right after the former parent. Fails with
    /// `InvalidOperation` when the block is already at the leaf root.
    pub fn outdent_block(&self, leaf_id: String, block_id: String) -> Result<(), PinkhaError> {
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        use_cases::outdent_block(&self.uow(), leaf_uuid, block_uuid).map_err(PinkhaError::from)
    }

    /// Searches leaf titles for `query` (case-insensitive).
    pub fn search_leaves(&self, query: String) -> Result<Vec<LeafMetaFfi>, PinkhaError> {
        validate_string(&query, "query")?;
        let metas = use_cases::search_leaves(&self.uow(), &query).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(leaf_meta_to_ffi).collect())
    }

    /// Full-text search across all block content in all leaves (case-insensitive).
    pub fn search_in_blocks(&self, query: String) -> Result<Vec<LeafMetaFfi>, PinkhaError> {
        validate_string(&query, "query")?;
        let metas = use_cases::search_in_blocks(&self.uow(), &query).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(leaf_meta_to_ffi).collect())
    }

    /// Case-insensitive search across book titles.
    pub fn search_books(&self, query: String) -> Result<Vec<BookMetaFfi>, PinkhaError> {
        validate_string(&query, "query")?;
        let metas = use_cases::search_books(&self.uow(), &query).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(book_meta_to_ffi).collect())
    }

    /// Block-content search returning each match together with a short
    /// preview snippet (~40 chars before / 80 after the term).
    pub fn search_in_blocks_with_snippets(
        &self,
        query: String,
    ) -> Result<Vec<BlockSearchHitFfi>, PinkhaError> {
        validate_string(&query, "query")?;
        let hits = use_cases::search_in_blocks_with_snippets(&self.uow(), &query)
            .map_err(PinkhaError::from)?;
        Ok(hits
            .into_iter()
            .map(|h| BlockSearchHitFfi {
                doc: leaf_meta_to_ffi(h.doc),
                block_id: h.block_id.to_string(),
                snippet: h.snippet,
            })
            .collect())
    }

    /// Case-insensitive search across shelf names.
    pub fn search_shelves(&self, query: String) -> Result<Vec<ShelfMetaFfi>, PinkhaError> {
        validate_string(&query, "query")?;
        let metas = use_cases::search_shelves(&self.uow(), &query).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(shelf_meta_to_ffi).collect())
    }

    // ── Trash (soft-deleted leaves) ────────────────────────────────────────

    /// Lists soft-deleted leaves (the trash). Newest-deleted first.
    pub fn list_deleted_leaves(&self) -> Result<Vec<LeafMetaFfi>, PinkhaError> {
        let metas = use_cases::list_deleted_leaves(&self.uow()).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(leaf_meta_to_ffi).collect())
    }

    /// Restores a soft-deleted leaf.
    pub fn restore_leaf(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        use_cases::restore_leaf(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Permanently deletes a soft-deleted leaf (purge from trash).
    pub fn purge_leaf(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        use_cases::purge_leaf(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Returns lightweight metadata for a single leaf — title, icon,
    /// cover, timestamps — without the block tree. Prefer this over
    /// `get_leaf_json` when only the chrome is needed (e.g. showing
    /// a linked doc's icon next to a book row).
    pub fn get_leaf_meta(&self, id: String) -> Result<LeafMetaFfi, PinkhaError> {
        let uuid = parse_uuid(&id)?;
        use_cases::get_leaf_meta(&self.uow(), uuid)
            .map(leaf_meta_to_ffi)
            .map_err(PinkhaError::from)
    }
}
