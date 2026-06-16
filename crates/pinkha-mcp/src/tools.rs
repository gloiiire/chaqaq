//! MCP tool registry + dispatcher for the pinkha surface.
//!
//! Each tool is two pieces: a static JSON-Schema description in
//! [`registry`] (what the client sees in `tools/list`) and a match
//! arm in [`dispatch`] (what runs when the client calls it).
//!
//! Tools that return JSON-shaped data forward the underlying
//! `*_json` FFI method's output verbatim — letting the agent reason
//! over the same JSON Swift consumes. Tools that return a single
//! id / count / structured FFI type emit a fresh JSON envelope so
//! the agent always receives `application/json`-ish text.

use std::sync::Arc;

use anyhow::{Context, Result, anyhow};
use pinkha::ffi::PinkhaApi;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

/// Full tool registry advertised on `tools/list`. Order is purely
/// cosmetic (grouped by domain) and has no semantic effect.
pub fn registry() -> Value {
    json!([
        // ── Leaves ─────────────────────────────────────────
        tool(
            "list_leaves",
            "List every non-deleted root leaf with its metadata.",
            obj_schema(&[])
        ),
        tool(
            "list_root_leaves",
            "Like list_leaves but excludes child pages (those reachable only via parent_leaf_id).",
            obj_schema(&[])
        ),
        tool(
            "list_child_leaves",
            "List the direct child leaves of a parent page.",
            obj_schema(&[("parent_leaf_id", "string", true, "Parent leaf UUID.")])
        ),
        tool(
            "get_leaf",
            "Return the full leaf (title, cover, icon, blocks tree) as a JSON object.",
            obj_schema(&[("id", "string", true, "Leaf UUID.")])
        ),
        tool(
            "create_leaf",
            "Create a new leaf with the given title and return its UUID.",
            obj_schema(&[("title", "string", true, "Plain-text title.")])
        ),
        tool(
            "delete_leaf",
            "Soft-delete a leaf — recoverable via restore_leaf.",
            obj_schema(&[("id", "string", true, "Leaf UUID.")])
        ),
        tool(
            "delete_all_leaves",
            "Soft-delete every leaf in the library; returns the deleted count.",
            obj_schema(&[])
        ),
        tool(
            "update_leaf_title",
            "Replace a leaf's plain-text title.",
            obj_schema(&[
                ("id", "string", true, "Leaf UUID."),
                ("new_title", "string", true, "Replacement title."),
            ])
        ),
        tool(
            "update_leaf_cover",
            "Replace or clear the leaf's cover image (URL, local filename, or null to clear).",
            obj_schema(&[
                ("id", "string", true, "Leaf UUID."),
                (
                    "cover",
                    "string",
                    false,
                    "Cover identifier or null to clear."
                ),
            ])
        ),
        tool(
            "update_leaf_icon",
            "Replace or clear the leaf's icon (emoji / filename / URL).",
            obj_schema(&[
                ("id", "string", true, "Leaf UUID."),
                ("icon", "string", false, "Icon identifier or null to clear."),
            ])
        ),
        tool(
            "update_leaf_published_at",
            "Override a leaf's user-editable publish_at timestamp. Empty string = reset to default (follows created_at).",
            obj_schema(&[
                ("id", "string", true, "Leaf UUID."),
                (
                    "new_published_at",
                    "string",
                    true,
                    "RFC 3339 timestamp or empty to reset."
                ),
            ])
        ),
        tool(
            "update_leaf_locked",
            "Toggle the leaf's read-only lock.",
            obj_schema(&[
                ("id", "string", true, "Leaf UUID."),
                ("locked", "boolean", true, "Lock state."),
            ])
        ),
        tool(
            "update_leaf_accent_color",
            "Override or clear the per-leaf accent color (color name like \"red\" / \"teal\", null to inherit settings).",
            obj_schema(&[
                ("id", "string", true, "Leaf UUID."),
                (
                    "accent_color",
                    "string",
                    false,
                    "Color name or null to clear."
                ),
            ])
        ),
        tool(
            "update_leaf_text_direction",
            "Override or clear the per-leaf writing direction (\"ltr\" / \"rtl\", null = system locale).",
            obj_schema(&[
                ("id", "string", true, "Leaf UUID."),
                (
                    "text_direction",
                    "string",
                    false,
                    "\"ltr\", \"rtl\" or null."
                ),
            ])
        ),
        tool(
            "update_leaf_parent",
            "Move a leaf under a new parent page (null = root).",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf to move."),
                (
                    "new_parent_leaf_id",
                    "string",
                    false,
                    "Target parent UUID, or null for root."
                ),
            ])
        ),
        // ── Blocks ────────────────────────────────────────────
        tool(
            "add_block",
            "Append a block to the leaf's top-level list. Content is a JSON-encoded BlockContent.",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf UUID."),
                (
                    "block_content_json",
                    "string",
                    true,
                    "Serialized BlockContent."
                ),
            ])
        ),
        tool(
            "add_child_block",
            "Add a block as a direct child of an existing block.",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf UUID."),
                ("parent_id", "string", true, "Parent block UUID."),
                (
                    "block_content_json",
                    "string",
                    true,
                    "Serialized BlockContent."
                ),
            ])
        ),
        tool(
            "update_block",
            "Replace the content of an existing block.",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf UUID."),
                ("block_id", "string", true, "Block UUID."),
                ("content_json", "string", true, "Serialized BlockContent."),
            ])
        ),
        tool(
            "delete_block",
            "Remove a block and all its children.",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf UUID."),
                ("block_id", "string", true, "Block UUID."),
            ])
        ),
        tool(
            "duplicate_block",
            "Deep-clone a block and insert the copy right after the original.",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf UUID."),
                ("block_id", "string", true, "Block UUID."),
            ])
        ),
        tool(
            "reorder_blocks",
            "Reorder root-level blocks. Blocks omitted from `order` are appended at the end.",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf UUID."),
                (
                    "order",
                    "array<string>",
                    true,
                    "Block UUIDs in the desired order."
                ),
            ])
        ),
        tool(
            "reorder_child_blocks",
            "Reorder a parent's direct children.",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf UUID."),
                ("parent_id", "string", true, "Parent block UUID."),
                (
                    "order",
                    "array<string>",
                    true,
                    "Child block UUIDs in the desired order."
                ),
            ])
        ),
        tool(
            "move_block",
            "Move a block to a new parent (null = root).",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf UUID."),
                ("block_id", "string", true, "Block UUID."),
                (
                    "new_parent_id",
                    "string",
                    false,
                    "Target parent UUID, or null for root."
                ),
            ])
        ),
        tool(
            "indent_block",
            "Indent a block under its previous sibling.",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf UUID."),
                ("block_id", "string", true, "Block UUID."),
            ])
        ),
        tool(
            "outdent_block",
            "Outdent a block to its grandparent's level.",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf UUID."),
                ("block_id", "string", true, "Block UUID."),
            ])
        ),
        tool(
            "set_block_color",
            "Set or clear the block-level foreground color name.",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf UUID."),
                ("block_id", "string", true, "Block UUID."),
                ("color", "string", false, "Color name or null to clear."),
            ])
        ),
        tool(
            "set_block_background_color",
            "Set or clear the block-level background highlight color.",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf UUID."),
                ("block_id", "string", true, "Block UUID."),
                (
                    "background_color",
                    "string",
                    false,
                    "Color name or null to clear."
                ),
            ])
        ),
        tool(
            "set_block_text_direction",
            "Override or clear the per-block writing direction (\"ltr\" / \"rtl\", null inherits the doc default).",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf UUID."),
                ("block_id", "string", true, "Block UUID."),
                (
                    "text_direction",
                    "string",
                    false,
                    "\"ltr\", \"rtl\" or null."
                ),
            ])
        ),
        // ── Trash ─────────────────────────────────────────────
        tool(
            "list_deleted_leaves",
            "List soft-deleted leaves.",
            obj_schema(&[])
        ),
        tool(
            "restore_leaf",
            "Restore a soft-deleted leaf.",
            obj_schema(&[("id", "string", true, "Leaf UUID.")])
        ),
        tool(
            "purge_leaf",
            "Permanently delete a soft-deleted leaf. Irreversible.",
            obj_schema(&[("id", "string", true, "Leaf UUID.")])
        ),
        // ── Search ────────────────────────────────────────────
        tool(
            "search_leaves",
            "Case-insensitive search across leaf titles.",
            obj_schema(&[("query", "string", true, "Search term.")])
        ),
        tool(
            "search_in_blocks",
            "Full-text search inside block content. Returns matching leaves.",
            obj_schema(&[("query", "string", true, "Search term.")])
        ),
        tool(
            "search_in_blocks_with_snippets",
            "Full-text search inside blocks, returning per-match snippets.",
            obj_schema(&[("query", "string", true, "Search term.")])
        ),
        tool(
            "search_books",
            "Case-insensitive search across book titles.",
            obj_schema(&[("query", "string", true, "Search term.")])
        ),
        tool(
            "search_shelves",
            "Case-insensitive search across shelf names.",
            obj_schema(&[("query", "string", true, "Search term.")])
        ),
        // ── Shelves ───────────────────────────────────────────
        tool(
            "create_shelf",
            "Create a new shelf (optionally nested) and return its UUID.",
            obj_schema(&[
                ("name", "string", true, "Shelf name."),
                (
                    "parent_id",
                    "string",
                    false,
                    "Parent shelf UUID, or null for root."
                ),
            ])
        ),
        tool(
            "list_shelves",
            "List every non-deleted shelf.",
            obj_schema(&[])
        ),
        tool(
            "get_shelf",
            "Get a single shelf's metadata.",
            obj_schema(&[("id", "string", true, "Shelf UUID.")])
        ),
        tool(
            "rename_shelf",
            "Rename a shelf.",
            obj_schema(&[
                ("id", "string", true, "Shelf UUID."),
                ("new_name", "string", true, "Replacement name."),
            ])
        ),
        tool(
            "update_shelf_icon",
            "Set or clear a shelf's icon.",
            obj_schema(&[
                ("id", "string", true, "Shelf UUID."),
                ("icon", "string", false, "Icon identifier or null to clear."),
            ])
        ),
        tool(
            "delete_shelf",
            "Soft-delete a shelf.",
            obj_schema(&[("id", "string", true, "Shelf UUID.")])
        ),
        tool(
            "move_shelf_to",
            "Move a shelf under a new parent (null = root).",
            obj_schema(&[
                ("shelf_id", "string", true, "Shelf to move."),
                (
                    "new_parent_id",
                    "string",
                    false,
                    "Target parent UUID, or null for root."
                ),
            ])
        ),
        tool(
            "move_leaf_to_shelf",
            "Move a leaf into a shelf (null = root).",
            obj_schema(&[
                ("leaf_id", "string", true, "Leaf UUID."),
                (
                    "shelf_id",
                    "string",
                    false,
                    "Target shelf UUID, or null for root."
                ),
            ])
        ),
        tool(
            "list_leaves_in_shelf",
            "List leaves inside the given shelf (null = root level only).",
            obj_schema(&[(
                "shelf_id",
                "string",
                false,
                "Shelf UUID, or null for root."
            ),])
        ),
        tool(
            "list_deleted_shelves",
            "List soft-deleted shelves.",
            obj_schema(&[])
        ),
        tool(
            "restore_shelf",
            "Restore a soft-deleted shelf.",
            obj_schema(&[("id", "string", true, "Shelf UUID.")])
        ),
        tool(
            "purge_shelf",
            "Permanently delete a soft-deleted shelf. Irreversible.",
            obj_schema(&[("id", "string", true, "Shelf UUID.")])
        ),
        // ── Books ─────────────────────────────────────────
        tool(
            "list_books",
            "List every non-deleted book.",
            obj_schema(&[])
        ),
        tool(
            "get_book",
            "Return the full book (schema + entries) as a JSON object.",
            obj_schema(&[("id", "string", true, "Book UUID.")])
        ),
        tool(
            "update_book_title",
            "Replace a book's plain-text title.",
            obj_schema(&[
                ("id", "string", true, "Book UUID."),
                ("new_title", "string", true, "Replacement title."),
            ])
        ),
        tool(
            "update_book_cover",
            "Replace or clear the book's cover image identifier (URL, local filename, or null to clear).",
            obj_schema(&[
                ("id", "string", true, "Book UUID."),
                (
                    "cover",
                    "string",
                    false,
                    "Cover identifier or null to clear."
                ),
            ])
        ),
        tool(
            "update_book_icon",
            "Replace or clear the book's icon (emoji / filename / URL).",
            obj_schema(&[
                ("id", "string", true, "Book UUID."),
                ("icon", "string", false, "Icon identifier or null to clear."),
            ])
        ),
        tool(
            "update_book_description",
            "Replace the book's rich-text description (empty string clears it).",
            obj_schema(&[
                ("id", "string", true, "Book UUID."),
                (
                    "description",
                    "string",
                    true,
                    "Description content or empty to clear."
                ),
            ])
        ),
        tool(
            "update_book_locked",
            "Toggle the book's read-only lock.",
            obj_schema(&[
                ("id", "string", true, "Book UUID."),
                ("locked", "boolean", true, "Lock state."),
            ])
        ),
        tool(
            "create_book",
            "Create a new book with the given title and return its UUID.",
            obj_schema(&[("title", "string", true, "Book title.")])
        ),
        tool(
            "delete_book",
            "Soft-delete a book.",
            obj_schema(&[("id", "string", true, "Book UUID.")])
        ),
        tool(
            "delete_all_books",
            "Soft-delete every book; returns the deleted count.",
            obj_schema(&[])
        ),
        tool(
            "list_deleted_books",
            "List soft-deleted books.",
            obj_schema(&[])
        ),
        tool(
            "restore_book",
            "Restore a soft-deleted book.",
            obj_schema(&[("id", "string", true, "Book UUID.")])
        ),
        tool(
            "purge_book",
            "Permanently delete a soft-deleted book. Irreversible.",
            obj_schema(&[("id", "string", true, "Book UUID.")])
        ),
        // ── Book entries ──────────────────────────────────
        tool(
            "add_entry",
            "Add an entry to a book. `values_json` = serialized HashMap<PropertyId,Value>.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("values_json", "string", true, "Serialized values map."),
            ])
        ),
        tool(
            "attach_leaf_to_book",
            "File an existing leaf as a row of an existing book. Same values_json shape as add_entry.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("leaf_id", "string", true, "Leaf UUID."),
                ("values_json", "string", true, "Serialized values map."),
            ])
        ),
        tool(
            "update_entry_published_at",
            "Override an entry's user-editable publish_at timestamp. Empty string = reset to default (follows created_at).",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("entry_id", "string", true, "Entry UUID."),
                (
                    "new_published_at",
                    "string",
                    true,
                    "RFC 3339 timestamp or empty to reset."
                ),
            ])
        ),
        tool(
            "update_entry",
            "Replace an entry's values.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("entry_id", "string", true, "Entry UUID."),
                ("values_json", "string", true, "Serialized values map."),
            ])
        ),
        tool(
            "delete_entry",
            "Soft-delete an entry.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("entry_id", "string", true, "Entry UUID."),
            ])
        ),
        tool(
            "restore_entry",
            "Restore a soft-deleted entry.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("entry_id", "string", true, "Entry UUID."),
            ])
        ),
        tool(
            "purge_entry",
            "Permanently delete a soft-deleted entry.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("entry_id", "string", true, "Entry UUID."),
            ])
        ),
        tool(
            "list_deleted_entries",
            "List soft-deleted entries in a book.",
            obj_schema(&[("book_id", "string", true, "Book UUID.")])
        ),
        // ── Book properties + views ───────────────────────
        tool(
            "add_property",
            "Add a property to a book schema.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("property_json", "string", true, "Serialized Property."),
            ])
        ),
        tool(
            "rename_property",
            "Rename a property.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("property_id", "string", true, "Property UUID."),
                ("new_name", "string", true, "Replacement name."),
            ])
        ),
        tool(
            "delete_property",
            "Delete a property and every value attached to it.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("property_id", "string", true, "Property UUID."),
            ])
        ),
        tool(
            "add_view",
            "Add a view (table / kanban / calendar / gallery) and return its UUID.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("view_json", "string", true, "Serialized View."),
            ])
        ),
        tool(
            "update_view",
            "Replace a view's filters + sorts.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("view_id", "string", true, "View UUID."),
                ("filters_json", "string", true, "Serialized filters."),
                ("sorts_json", "string", true, "Serialized sorts."),
            ])
        ),
        tool(
            "set_view_sort",
            "Set a single primary sort on a view (property + direction).",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("view_id", "string", true, "View UUID."),
                (
                    "property_id",
                    "string",
                    false,
                    "Property UUID to sort by, or null to clear."
                ),
                (
                    "ascending",
                    "boolean",
                    true,
                    "True for ascending, false for descending."
                ),
            ])
        ),
        tool(
            "delete_view",
            "Delete a view (refuses if it's the book's last view).",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("view_id", "string", true, "View UUID."),
            ])
        ),
        // ── Book queries ──────────────────────────────────
        tool(
            "query_book",
            "Run a view's filters + sorts and return the matching entries.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("view_id", "string", true, "View UUID."),
            ])
        ),
        tool(
            "query_book_with_rollups",
            "Like query_book but with rollup columns evaluated.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("view_id", "string", true, "View UUID."),
            ])
        ),
        tool(
            "grouped_query_book",
            "Group a view's results by a property.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("view_id", "string", true, "View UUID."),
                (
                    "group_by_property_id",
                    "string",
                    true,
                    "Property UUID to group by."
                ),
            ])
        ),
        tool(
            "column_aggregate_book",
            "Run a single aggregation (sum / avg / min / max / count) on one column.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("property_id", "string", true, "Property UUID."),
                (
                    "aggregate_json",
                    "string",
                    true,
                    "Serialized Aggregate enum."
                ),
            ])
        ),
        tool(
            "search_book_entries",
            "Case-insensitive full-text search across one book's entries.",
            obj_schema(&[
                ("book_id", "string", true, "Book UUID."),
                ("query", "string", true, "Search term."),
            ])
        ),
    ])
}

/// Routes a tool call to the matching FFI method. Returns the text
/// body to wrap in the MCP `content` array.
pub fn dispatch(api: &Arc<PinkhaApi>, name: &str, args: Value) -> Result<String> {
    match name {
        // ── Leaves ─────────────────────────────────────────
        "list_leaves" => json_of(api.list_leaves()?),
        "list_root_leaves" => json_of(api.list_root_leaves()?),
        "list_child_leaves" => {
            let parent: String = take(&args, "parent_leaf_id")?;
            json_of(api.list_child_leaves(parent)?)
        }
        "get_leaf" => {
            let id: String = take(&args, "id")?;
            Ok(api.get_leaf_json(id)?)
        }
        "create_leaf" => {
            let title: String = take(&args, "title")?;
            Ok(json!({ "id": api.create_leaf(title)? }).to_string())
        }
        "delete_leaf" => {
            let id: String = take(&args, "id")?;
            api.delete_leaf(id)?;
            ok()
        }
        "delete_all_leaves" => Ok(json!({ "deleted": api.delete_all_leaves()? }).to_string()),
        "update_leaf_title" => {
            api.update_leaf_title(take(&args, "id")?, take(&args, "new_title")?)?;
            ok()
        }
        "update_leaf_cover" => {
            api.update_leaf_cover(take(&args, "id")?, take_opt(&args, "cover")?)?;
            ok()
        }
        "update_leaf_icon" => {
            api.update_leaf_icon(take(&args, "id")?, take_opt(&args, "icon")?)?;
            ok()
        }
        "update_leaf_locked" => {
            api.update_leaf_locked(take(&args, "id")?, take(&args, "locked")?)?;
            ok()
        }
        "update_leaf_published_at" => {
            api.update_leaf_published_at(take(&args, "id")?, take(&args, "new_published_at")?)?;
            ok()
        }
        "update_leaf_accent_color" => {
            api.update_leaf_accent_color(take(&args, "id")?, take_opt(&args, "accent_color")?)?;
            ok()
        }
        "update_leaf_text_direction" => {
            api.update_leaf_text_direction(
                take(&args, "id")?,
                take_opt(&args, "text_direction")?,
            )?;
            ok()
        }
        "update_leaf_parent" => {
            api.update_leaf_parent(
                take(&args, "leaf_id")?,
                take_opt(&args, "new_parent_leaf_id")?,
            )?;
            ok()
        }

        // ── Blocks ────────────────────────────────────────────
        "add_block" => Ok(json!({
            "block_id": api.add_block(
                take(&args, "leaf_id")?,
                take(&args, "block_content_json")?,
            )?,
        })
        .to_string()),
        "add_child_block" => Ok(json!({
            "block_id": api.add_child_block(
                take(&args, "leaf_id")?,
                take(&args, "parent_id")?,
                take(&args, "block_content_json")?,
            )?,
        })
        .to_string()),
        "update_block" => {
            api.update_block(
                take(&args, "leaf_id")?,
                take(&args, "block_id")?,
                take(&args, "content_json")?,
            )?;
            ok()
        }
        "delete_block" => {
            api.delete_block(take(&args, "leaf_id")?, take(&args, "block_id")?)?;
            ok()
        }
        "duplicate_block" => Ok(json!({
            "block_id": api.duplicate_block(
                take(&args, "leaf_id")?,
                take(&args, "block_id")?,
            )?,
        })
        .to_string()),
        "reorder_blocks" => {
            api.reorder_blocks(take(&args, "leaf_id")?, take(&args, "order")?)?;
            ok()
        }
        "reorder_child_blocks" => {
            api.reorder_child_blocks(
                take(&args, "leaf_id")?,
                take(&args, "parent_id")?,
                take(&args, "order")?,
            )?;
            ok()
        }
        "move_block" => {
            api.move_block(
                take(&args, "leaf_id")?,
                take(&args, "block_id")?,
                take_opt(&args, "new_parent_id")?,
            )?;
            ok()
        }
        "indent_block" => {
            api.indent_block(take(&args, "leaf_id")?, take(&args, "block_id")?)?;
            ok()
        }
        "outdent_block" => {
            api.outdent_block(take(&args, "leaf_id")?, take(&args, "block_id")?)?;
            ok()
        }
        "set_block_color" => {
            api.set_block_color(
                take(&args, "leaf_id")?,
                take(&args, "block_id")?,
                take_opt(&args, "color")?,
            )?;
            ok()
        }
        "set_block_background_color" => {
            api.set_block_background_color(
                take(&args, "leaf_id")?,
                take(&args, "block_id")?,
                take_opt(&args, "background_color")?,
            )?;
            ok()
        }
        "set_block_text_direction" => {
            api.set_block_text_direction(
                take(&args, "leaf_id")?,
                take(&args, "block_id")?,
                take_opt(&args, "text_direction")?,
            )?;
            ok()
        }

        // ── Trash ─────────────────────────────────────────────
        "list_deleted_leaves" => json_of(api.list_deleted_leaves()?),
        "restore_leaf" => {
            api.restore_leaf(take(&args, "id")?)?;
            ok()
        }
        "purge_leaf" => {
            api.purge_leaf(take(&args, "id")?)?;
            ok()
        }

        // ── Search ────────────────────────────────────────────
        "search_leaves" => json_of(api.search_leaves(take(&args, "query")?)?),
        "search_in_blocks" => json_of(api.search_in_blocks(take(&args, "query")?)?),
        "search_in_blocks_with_snippets" => {
            json_of(api.search_in_blocks_with_snippets(take(&args, "query")?)?)
        }
        "search_books" => json_of(api.search_books(take(&args, "query")?)?),
        "search_shelves" => json_of(api.search_shelves(take(&args, "query")?)?),

        // ── Shelves ───────────────────────────────────────────
        "create_shelf" => {
            let meta = api.create_shelf(take(&args, "name")?, take_opt(&args, "parent_id")?)?;
            Ok(json!({ "id": meta.id }).to_string())
        }
        "list_shelves" => json_of(api.list_shelves()?),
        "get_shelf" => json_of(api.get_shelf(take(&args, "id")?)?),
        "rename_shelf" => {
            api.rename_shelf(take(&args, "id")?, take(&args, "new_name")?)?;
            ok()
        }
        "update_shelf_icon" => {
            api.update_shelf_icon(take(&args, "id")?, take_opt(&args, "icon")?)?;
            ok()
        }
        "delete_shelf" => {
            api.delete_shelf(take(&args, "id")?)?;
            ok()
        }
        "move_shelf_to" => {
            api.move_shelf_to(take(&args, "shelf_id")?, take_opt(&args, "new_parent_id")?)?;
            ok()
        }
        "move_leaf_to_shelf" => {
            api.move_leaf_to_shelf(take(&args, "leaf_id")?, take_opt(&args, "shelf_id")?)?;
            ok()
        }
        "list_leaves_in_shelf" => {
            json_of(api.list_leaves_in_shelf(take_opt(&args, "shelf_id")?)?)
        }
        "list_deleted_shelves" => json_of(api.list_deleted_shelves()?),
        "restore_shelf" => {
            api.restore_shelf(take(&args, "id")?)?;
            ok()
        }
        "purge_shelf" => {
            api.purge_shelf(take(&args, "id")?)?;
            ok()
        }

        // ── Books ─────────────────────────────────────────
        "list_books" => json_of(api.list_books()?),
        "get_book" => Ok(api.get_book_json(take(&args, "id")?)?),
        "update_book_title" => {
            api.update_book_title(take(&args, "id")?, take(&args, "new_title")?)?;
            ok()
        }
        "update_book_cover" => {
            api.update_book_cover(take(&args, "id")?, take_opt(&args, "cover")?)?;
            ok()
        }
        "update_book_icon" => {
            api.update_book_icon(take(&args, "id")?, take_opt(&args, "icon")?)?;
            ok()
        }
        "update_book_description" => {
            api.update_book_description(take(&args, "id")?, take(&args, "description")?)?;
            ok()
        }
        "update_book_locked" => {
            api.update_book_locked(take(&args, "id")?, take(&args, "locked")?)?;
            ok()
        }
        "create_book" => Ok(json!({
            "id": api.create_book(take(&args, "title")?)?,
        })
        .to_string()),
        "delete_book" => {
            api.delete_book(take(&args, "id")?)?;
            ok()
        }
        "delete_all_books" => Ok(json!({
            "deleted": api.delete_all_books()?,
        })
        .to_string()),
        "list_deleted_books" => json_of(api.list_deleted_books()?),
        "restore_book" => {
            api.restore_book(take(&args, "id")?)?;
            ok()
        }
        "purge_book" => {
            api.purge_book(take(&args, "id")?)?;
            ok()
        }

        // ── Book entries ──────────────────────────────────
        "add_entry" => Ok(json!({
            "entry_id": api.add_entry(
                take(&args, "book_id")?,
                take(&args, "values_json")?,
            )?,
        })
        .to_string()),
        "attach_leaf_to_book" => Ok(json!({
            "entry_id": api.attach_leaf_to_book(
                take(&args, "book_id")?,
                take(&args, "leaf_id")?,
                take(&args, "values_json")?,
            )?,
        })
        .to_string()),
        "update_entry" => {
            api.update_entry(
                take(&args, "book_id")?,
                take(&args, "entry_id")?,
                take(&args, "values_json")?,
            )?;
            ok()
        }
        "update_entry_published_at" => {
            api.update_entry_published_at(
                take(&args, "book_id")?,
                take(&args, "entry_id")?,
                take(&args, "new_published_at")?,
            )?;
            ok()
        }
        "delete_entry" => {
            api.delete_entry(take(&args, "book_id")?, take(&args, "entry_id")?)?;
            ok()
        }
        "restore_entry" => {
            api.restore_entry(take(&args, "book_id")?, take(&args, "entry_id")?)?;
            ok()
        }
        "purge_entry" => {
            api.purge_entry(take(&args, "book_id")?, take(&args, "entry_id")?)?;
            ok()
        }
        "list_deleted_entries" => Ok(api.list_deleted_entries_json(take(&args, "book_id")?)?),

        // ── Book properties + views ───────────────────────
        "add_property" => {
            api.add_property(take(&args, "book_id")?, take(&args, "property_json")?)?;
            ok()
        }
        "rename_property" => {
            api.rename_property(
                take(&args, "book_id")?,
                take(&args, "property_id")?,
                take(&args, "new_name")?,
            )?;
            ok()
        }
        "delete_property" => {
            api.delete_property(take(&args, "book_id")?, take(&args, "property_id")?)?;
            ok()
        }
        "add_view" => Ok(json!({
            "view_id": api.add_view(take(&args, "book_id")?, take(&args, "view_json")?)?,
        })
        .to_string()),
        "update_view" => {
            api.update_view(
                take(&args, "book_id")?,
                take(&args, "view_id")?,
                take(&args, "filters_json")?,
                take(&args, "sorts_json")?,
            )?;
            ok()
        }
        "set_view_sort" => {
            api.set_view_sort(
                take(&args, "book_id")?,
                take(&args, "view_id")?,
                take_opt(&args, "property_id")?,
                take(&args, "ascending")?,
            )?;
            ok()
        }
        "delete_view" => {
            api.delete_view(take(&args, "book_id")?, take(&args, "view_id")?)?;
            ok()
        }

        // ── Book queries ──────────────────────────────────
        "query_book" => {
            Ok(api.query_book_json(take(&args, "book_id")?, take(&args, "view_id")?)?)
        }
        "query_book_with_rollups" => {
            Ok(api
                .query_book_with_rollups_json(take(&args, "book_id")?, take(&args, "view_id")?)?)
        }
        "grouped_query_book" => Ok(api.grouped_query_book_json(
            take(&args, "book_id")?,
            take(&args, "view_id")?,
            take(&args, "group_by_property_id")?,
        )?),
        "column_aggregate_book" => Ok(api.column_aggregate_book_json(
            take(&args, "book_id")?,
            take(&args, "property_id")?,
            take(&args, "aggregate_json")?,
        )?),
        "search_book_entries" => {
            Ok(api.search_book_entries_json(take(&args, "book_id")?, take(&args, "query")?)?)
        }

        _ => Err(anyhow!("unknown tool: {name}")),
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────

/// Pulls a required arg out of the arguments object, deserializing
/// into the caller's target type. Returns a descriptive error if the
/// key is missing or has the wrong shape.
fn take<T: DeserializeOwned>(args: &Value, key: &str) -> Result<T> {
    let v = args
        .get(key)
        .cloned()
        .ok_or_else(|| anyhow!("missing required argument: {key}"))?;
    serde_json::from_value(v).with_context(|| format!("invalid argument {key}"))
}

/// Like [`take`] but tolerates a missing key or an explicit JSON `null`,
/// mapping both to `None`. Used for the `Option<String>` style FFI args
/// (icon, cover, parent ids, optional colours...).
fn take_opt<T: DeserializeOwned>(args: &Value, key: &str) -> Result<Option<T>> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => Ok(Some(
            serde_json::from_value(v.clone()).with_context(|| format!("invalid argument {key}"))?,
        )),
    }
}

/// Serializes any FFI return value to a JSON string for the MCP
/// `content[].text` payload.
fn json_of<T: serde::Serialize>(value: T) -> Result<String> {
    serde_json::to_string(&value).context("failed to serialize result")
}

/// Standard "this was a write, no body" envelope.
fn ok() -> Result<String> {
    Ok(json!({ "ok": true }).to_string())
}

// ── Tool definition builders ────────────────────────────────────────────

/// Builds the JSON-Schema-ish input descriptor for a tool.
/// `(name, type, required, description)` per arg.
fn obj_schema(fields: &[(&str, &str, bool, &str)]) -> Value {
    let mut properties = serde_json::Map::new();
    let mut required = Vec::new();
    for (name, ty, req, desc) in fields {
        properties.insert(
            (*name).to_string(),
            json!({ "type": ty, "description": desc }),
        );
        if *req {
            required.push(json!(*name));
        }
    }
    json!({
        "type": "object",
        "properties": Value::Object(properties),
        "required": Value::Array(required),
    })
}

fn tool(name: &str, description: &str, input_schema: Value) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": input_schema,
    })
}
