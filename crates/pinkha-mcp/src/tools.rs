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
        // ── Documents ─────────────────────────────────────────
        tool("list_documents",
            "List every non-deleted root document with its metadata.",
            obj_schema(&[])),
        tool("list_root_documents",
            "Like list_documents but excludes child pages (those reachable only via parent_doc_id).",
            obj_schema(&[])),
        tool("list_child_documents",
            "List the direct child documents of a parent page.",
            obj_schema(&[("parent_doc_id", "string", true, "Parent document UUID.")])),
        tool("get_document",
            "Return the full document (title, cover, icon, blocks tree) as a JSON object.",
            obj_schema(&[("id", "string", true, "Document UUID.")])),
        tool("create_document",
            "Create a new document with the given title and return its UUID.",
            obj_schema(&[("title", "string", true, "Plain-text title.")])),
        tool("delete_document",
            "Soft-delete a document — recoverable via restore_document.",
            obj_schema(&[("id", "string", true, "Document UUID.")])),
        tool("delete_all_documents",
            "Soft-delete every document in the workspace; returns the deleted count.",
            obj_schema(&[])),
        tool("update_document_title",
            "Replace a document's plain-text title.",
            obj_schema(&[
                ("id", "string", true, "Document UUID."),
                ("new_title", "string", true, "Replacement title."),
            ])),
        tool("update_document_cover",
            "Replace or clear the document's cover image (URL, local filename, or null to clear).",
            obj_schema(&[
                ("id", "string", true, "Document UUID."),
                ("cover", "string", false, "Cover identifier or null to clear."),
            ])),
        tool("update_document_icon",
            "Replace or clear the document's icon (emoji / filename / URL).",
            obj_schema(&[
                ("id", "string", true, "Document UUID."),
                ("icon", "string", false, "Icon identifier or null to clear."),
            ])),
        tool("update_document_published_at",
            "Override a document's user-editable publish_at timestamp. Empty string = reset to default (follows created_at).",
            obj_schema(&[
                ("id", "string", true, "Document UUID."),
                ("new_published_at", "string", true, "RFC 3339 timestamp or empty to reset."),
            ])),
        tool("update_document_locked",
            "Toggle the document's read-only lock.",
            obj_schema(&[
                ("id", "string", true, "Document UUID."),
                ("locked", "boolean", true, "Lock state."),
            ])),
        tool("update_document_accent_color",
            "Override or clear the per-document accent color (color name like \"red\" / \"teal\", null to inherit settings).",
            obj_schema(&[
                ("id", "string", true, "Document UUID."),
                ("accent_color", "string", false, "Color name or null to clear."),
            ])),
        tool("update_document_text_direction",
            "Override or clear the per-document writing direction (\"ltr\" / \"rtl\", null = system locale).",
            obj_schema(&[
                ("id", "string", true, "Document UUID."),
                ("text_direction", "string", false, "\"ltr\", \"rtl\" or null."),
            ])),
        tool("update_document_parent",
            "Move a document under a new parent page (null = root).",
            obj_schema(&[
                ("doc_id", "string", true, "Document to move."),
                ("new_parent_doc_id", "string", false, "Target parent UUID, or null for root."),
            ])),

        // ── Blocks ────────────────────────────────────────────
        tool("add_block",
            "Append a block to the document's top-level list. Content is a JSON-encoded BlockContent.",
            obj_schema(&[
                ("doc_id", "string", true, "Document UUID."),
                ("block_content_json", "string", true, "Serialized BlockContent."),
            ])),
        tool("add_child_block",
            "Add a block as a direct child of an existing block.",
            obj_schema(&[
                ("doc_id", "string", true, "Document UUID."),
                ("parent_id", "string", true, "Parent block UUID."),
                ("block_content_json", "string", true, "Serialized BlockContent."),
            ])),
        tool("update_block",
            "Replace the content of an existing block.",
            obj_schema(&[
                ("doc_id", "string", true, "Document UUID."),
                ("block_id", "string", true, "Block UUID."),
                ("content_json", "string", true, "Serialized BlockContent."),
            ])),
        tool("delete_block",
            "Remove a block and all its children.",
            obj_schema(&[
                ("doc_id", "string", true, "Document UUID."),
                ("block_id", "string", true, "Block UUID."),
            ])),
        tool("duplicate_block",
            "Deep-clone a block and insert the copy right after the original.",
            obj_schema(&[
                ("doc_id", "string", true, "Document UUID."),
                ("block_id", "string", true, "Block UUID."),
            ])),
        tool("reorder_blocks",
            "Reorder root-level blocks. Blocks omitted from `order` are appended at the end.",
            obj_schema(&[
                ("doc_id", "string", true, "Document UUID."),
                ("order", "array<string>", true, "Block UUIDs in the desired order."),
            ])),
        tool("reorder_child_blocks",
            "Reorder a parent's direct children.",
            obj_schema(&[
                ("doc_id", "string", true, "Document UUID."),
                ("parent_id", "string", true, "Parent block UUID."),
                ("order", "array<string>", true, "Child block UUIDs in the desired order."),
            ])),
        tool("move_block",
            "Move a block to a new parent (null = root).",
            obj_schema(&[
                ("doc_id", "string", true, "Document UUID."),
                ("block_id", "string", true, "Block UUID."),
                ("new_parent_id", "string", false, "Target parent UUID, or null for root."),
            ])),
        tool("indent_block",
            "Indent a block under its previous sibling.",
            obj_schema(&[
                ("doc_id", "string", true, "Document UUID."),
                ("block_id", "string", true, "Block UUID."),
            ])),
        tool("outdent_block",
            "Outdent a block to its grandparent's level.",
            obj_schema(&[
                ("doc_id", "string", true, "Document UUID."),
                ("block_id", "string", true, "Block UUID."),
            ])),
        tool("set_block_color",
            "Set or clear the block-level foreground color name.",
            obj_schema(&[
                ("doc_id", "string", true, "Document UUID."),
                ("block_id", "string", true, "Block UUID."),
                ("color", "string", false, "Color name or null to clear."),
            ])),
        tool("set_block_background_color",
            "Set or clear the block-level background highlight color.",
            obj_schema(&[
                ("doc_id", "string", true, "Document UUID."),
                ("block_id", "string", true, "Block UUID."),
                ("background_color", "string", false, "Color name or null to clear."),
            ])),
        tool("set_block_text_direction",
            "Override or clear the per-block writing direction (\"ltr\" / \"rtl\", null inherits the doc default).",
            obj_schema(&[
                ("doc_id", "string", true, "Document UUID."),
                ("block_id", "string", true, "Block UUID."),
                ("text_direction", "string", false, "\"ltr\", \"rtl\" or null."),
            ])),

        // ── Trash ─────────────────────────────────────────────
        tool("list_deleted_documents",
            "List soft-deleted documents.",
            obj_schema(&[])),
        tool("restore_document",
            "Restore a soft-deleted document.",
            obj_schema(&[("id", "string", true, "Document UUID.")])),
        tool("purge_document",
            "Permanently delete a soft-deleted document. Irreversible.",
            obj_schema(&[("id", "string", true, "Document UUID.")])),

        // ── Search ────────────────────────────────────────────
        tool("search_documents",
            "Case-insensitive search across document titles.",
            obj_schema(&[("query", "string", true, "Search term.")])),
        tool("search_in_blocks",
            "Full-text search inside block content. Returns matching documents.",
            obj_schema(&[("query", "string", true, "Search term.")])),
        tool("search_in_blocks_with_snippets",
            "Full-text search inside blocks, returning per-match snippets.",
            obj_schema(&[("query", "string", true, "Search term.")])),
        tool("search_databases",
            "Case-insensitive search across database titles.",
            obj_schema(&[("query", "string", true, "Search term.")])),
        tool("search_folders",
            "Case-insensitive search across folder names.",
            obj_schema(&[("query", "string", true, "Search term.")])),

        // ── Folders ───────────────────────────────────────────
        tool("create_folder",
            "Create a new folder (optionally nested) and return its UUID.",
            obj_schema(&[
                ("name", "string", true, "Folder name."),
                ("parent_id", "string", false, "Parent folder UUID, or null for root."),
            ])),
        tool("list_folders",
            "List every non-deleted folder.",
            obj_schema(&[])),
        tool("get_folder",
            "Get a single folder's metadata.",
            obj_schema(&[("id", "string", true, "Folder UUID.")])),
        tool("rename_folder",
            "Rename a folder.",
            obj_schema(&[
                ("id", "string", true, "Folder UUID."),
                ("new_name", "string", true, "Replacement name."),
            ])),
        tool("update_folder_icon",
            "Set or clear a folder's icon.",
            obj_schema(&[
                ("id", "string", true, "Folder UUID."),
                ("icon", "string", false, "Icon identifier or null to clear."),
            ])),
        tool("delete_folder",
            "Soft-delete a folder.",
            obj_schema(&[("id", "string", true, "Folder UUID.")])),
        tool("move_folder_to",
            "Move a folder under a new parent (null = root).",
            obj_schema(&[
                ("folder_id", "string", true, "Folder to move."),
                ("new_parent_id", "string", false, "Target parent UUID, or null for root."),
            ])),
        tool("move_document_to_folder",
            "Move a document into a folder (null = root).",
            obj_schema(&[
                ("doc_id", "string", true, "Document UUID."),
                ("folder_id", "string", false, "Target folder UUID, or null for root."),
            ])),
        tool("list_documents_in_folder",
            "List documents inside the given folder (null = root level only).",
            obj_schema(&[
                ("folder_id", "string", false, "Folder UUID, or null for root."),
            ])),
        tool("list_deleted_folders",
            "List soft-deleted folders.",
            obj_schema(&[])),
        tool("restore_folder",
            "Restore a soft-deleted folder.",
            obj_schema(&[("id", "string", true, "Folder UUID.")])),
        tool("purge_folder",
            "Permanently delete a soft-deleted folder. Irreversible.",
            obj_schema(&[("id", "string", true, "Folder UUID.")])),

        // ── Databases ─────────────────────────────────────────
        tool("list_databases",
            "List every non-deleted database.",
            obj_schema(&[])),
        tool("get_database",
            "Return the full database (schema + entries) as a JSON object.",
            obj_schema(&[("id", "string", true, "Database UUID.")])),
        tool("update_database_title",
            "Replace a database's plain-text title.",
            obj_schema(&[
                ("id", "string", true, "Database UUID."),
                ("new_title", "string", true, "Replacement title."),
            ])),
        tool("update_database_cover",
            "Replace or clear the database's cover image identifier (URL, local filename, or null to clear).",
            obj_schema(&[
                ("id", "string", true, "Database UUID."),
                ("cover", "string", false, "Cover identifier or null to clear."),
            ])),
        tool("update_database_icon",
            "Replace or clear the database's icon (emoji / filename / URL).",
            obj_schema(&[
                ("id", "string", true, "Database UUID."),
                ("icon", "string", false, "Icon identifier or null to clear."),
            ])),
        tool("update_database_description",
            "Replace the database's rich-text description (empty string clears it).",
            obj_schema(&[
                ("id", "string", true, "Database UUID."),
                ("description", "string", true, "Description content or empty to clear."),
            ])),
        tool("update_database_locked",
            "Toggle the database's read-only lock.",
            obj_schema(&[
                ("id", "string", true, "Database UUID."),
                ("locked", "boolean", true, "Lock state."),
            ])),
        tool("create_database",
            "Create a new database with the given title and return its UUID.",
            obj_schema(&[("title", "string", true, "Database title.")])),
        tool("delete_database",
            "Soft-delete a database.",
            obj_schema(&[("id", "string", true, "Database UUID.")])),
        tool("delete_all_databases",
            "Soft-delete every database; returns the deleted count.",
            obj_schema(&[])),
        tool("list_deleted_databases",
            "List soft-deleted databases.",
            obj_schema(&[])),
        tool("restore_database",
            "Restore a soft-deleted database.",
            obj_schema(&[("id", "string", true, "Database UUID.")])),
        tool("purge_database",
            "Permanently delete a soft-deleted database. Irreversible.",
            obj_schema(&[("id", "string", true, "Database UUID.")])),

        // ── Database entries ──────────────────────────────────
        tool("add_entry",
            "Add an entry to a database. `values_json` = serialized HashMap<PropertyId,Value>.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("values_json", "string", true, "Serialized values map."),
            ])),
        tool("attach_document_to_database",
            "File an existing document as a row of an existing database. Same values_json shape as add_entry.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("doc_id", "string", true, "Document UUID."),
                ("values_json", "string", true, "Serialized values map."),
            ])),
        tool("update_entry_published_at",
            "Override an entry's user-editable publish_at timestamp. Empty string = reset to default (follows created_at).",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("entry_id", "string", true, "Entry UUID."),
                ("new_published_at", "string", true, "RFC 3339 timestamp or empty to reset."),
            ])),
        tool("update_entry",
            "Replace an entry's values.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("entry_id", "string", true, "Entry UUID."),
                ("values_json", "string", true, "Serialized values map."),
            ])),
        tool("delete_entry",
            "Soft-delete an entry.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("entry_id", "string", true, "Entry UUID."),
            ])),
        tool("restore_entry",
            "Restore a soft-deleted entry.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("entry_id", "string", true, "Entry UUID."),
            ])),
        tool("purge_entry",
            "Permanently delete a soft-deleted entry.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("entry_id", "string", true, "Entry UUID."),
            ])),
        tool("list_deleted_entries",
            "List soft-deleted entries in a database.",
            obj_schema(&[("db_id", "string", true, "Database UUID.")])),

        // ── Database properties + views ───────────────────────
        tool("add_property",
            "Add a property to a database schema.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("property_json", "string", true, "Serialized Property."),
            ])),
        tool("rename_property",
            "Rename a property.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("property_id", "string", true, "Property UUID."),
                ("new_name", "string", true, "Replacement name."),
            ])),
        tool("delete_property",
            "Delete a property and every value attached to it.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("property_id", "string", true, "Property UUID."),
            ])),
        tool("add_view",
            "Add a view (table / kanban / calendar / gallery) and return its UUID.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("view_json", "string", true, "Serialized View."),
            ])),
        tool("update_view",
            "Replace a view's filters + sorts.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("view_id", "string", true, "View UUID."),
                ("filters_json", "string", true, "Serialized filters."),
                ("sorts_json", "string", true, "Serialized sorts."),
            ])),
        tool("set_view_sort",
            "Set a single primary sort on a view (property + direction).",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("view_id", "string", true, "View UUID."),
                ("property_id", "string", false, "Property UUID to sort by, or null to clear."),
                ("ascending", "boolean", true, "True for ascending, false for descending."),
            ])),
        tool("delete_view",
            "Delete a view (refuses if it's the database's last view).",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("view_id", "string", true, "View UUID."),
            ])),

        // ── Database queries ──────────────────────────────────
        tool("query_database",
            "Run a view's filters + sorts and return the matching entries.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("view_id", "string", true, "View UUID."),
            ])),
        tool("query_database_with_rollups",
            "Like query_database but with rollup columns evaluated.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("view_id", "string", true, "View UUID."),
            ])),
        tool("grouped_query_database",
            "Group a view's results by a property.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("view_id", "string", true, "View UUID."),
                ("group_by_property_id", "string", true, "Property UUID to group by."),
            ])),
        tool("column_aggregate_database",
            "Run a single aggregation (sum / avg / min / max / count) on one column.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("property_id", "string", true, "Property UUID."),
                ("aggregate_json", "string", true, "Serialized Aggregate enum."),
            ])),
        tool("search_database_entries",
            "Case-insensitive full-text search across one database's entries.",
            obj_schema(&[
                ("db_id", "string", true, "Database UUID."),
                ("query", "string", true, "Search term."),
            ])),
    ])
}

/// Routes a tool call to the matching FFI method. Returns the text
/// body to wrap in the MCP `content` array.
pub fn dispatch(api: &Arc<PinkhaApi>, name: &str, args: Value) -> Result<String> {
    match name {
        // ── Documents ─────────────────────────────────────────
        "list_documents" => json_of(api.list_documents()?),
        "list_root_documents" => json_of(api.list_root_documents()?),
        "list_child_documents" => {
            let parent: String = take(&args, "parent_doc_id")?;
            json_of(api.list_child_documents(parent)?)
        }
        "get_document" => {
            let id: String = take(&args, "id")?;
            Ok(api.get_document_json(id)?)
        }
        "create_document" => {
            let title: String = take(&args, "title")?;
            Ok(json!({ "id": api.create_document(title)? }).to_string())
        }
        "delete_document" => {
            let id: String = take(&args, "id")?;
            api.delete_document(id)?;
            ok()
        }
        "delete_all_documents" => Ok(json!({ "deleted": api.delete_all_documents()? }).to_string()),
        "update_document_title" => {
            api.update_document_title(take(&args, "id")?, take(&args, "new_title")?)?;
            ok()
        }
        "update_document_cover" => {
            api.update_document_cover(take(&args, "id")?, take_opt(&args, "cover")?)?;
            ok()
        }
        "update_document_icon" => {
            api.update_document_icon(take(&args, "id")?, take_opt(&args, "icon")?)?;
            ok()
        }
        "update_document_locked" => {
            api.update_document_locked(take(&args, "id")?, take(&args, "locked")?)?;
            ok()
        }
        "update_document_published_at" => {
            api.update_document_published_at(
                take(&args, "id")?,
                take(&args, "new_published_at")?,
            )?;
            ok()
        }
        "update_document_accent_color" => {
            api.update_document_accent_color(take(&args, "id")?, take_opt(&args, "accent_color")?)?;
            ok()
        }
        "update_document_text_direction" => {
            api.update_document_text_direction(
                take(&args, "id")?,
                take_opt(&args, "text_direction")?,
            )?;
            ok()
        }
        "update_document_parent" => {
            api.update_document_parent(
                take(&args, "doc_id")?,
                take_opt(&args, "new_parent_doc_id")?,
            )?;
            ok()
        }

        // ── Blocks ────────────────────────────────────────────
        "add_block" => Ok(json!({
            "block_id": api.add_block(
                take(&args, "doc_id")?,
                take(&args, "block_content_json")?,
            )?,
        }).to_string()),
        "add_child_block" => Ok(json!({
            "block_id": api.add_child_block(
                take(&args, "doc_id")?,
                take(&args, "parent_id")?,
                take(&args, "block_content_json")?,
            )?,
        }).to_string()),
        "update_block" => {
            api.update_block(
                take(&args, "doc_id")?,
                take(&args, "block_id")?,
                take(&args, "content_json")?,
            )?;
            ok()
        }
        "delete_block" => {
            api.delete_block(take(&args, "doc_id")?, take(&args, "block_id")?)?;
            ok()
        }
        "duplicate_block" => Ok(json!({
            "block_id": api.duplicate_block(
                take(&args, "doc_id")?,
                take(&args, "block_id")?,
            )?,
        }).to_string()),
        "reorder_blocks" => {
            api.reorder_blocks(take(&args, "doc_id")?, take(&args, "order")?)?;
            ok()
        }
        "reorder_child_blocks" => {
            api.reorder_child_blocks(
                take(&args, "doc_id")?,
                take(&args, "parent_id")?,
                take(&args, "order")?,
            )?;
            ok()
        }
        "move_block" => {
            api.move_block(
                take(&args, "doc_id")?,
                take(&args, "block_id")?,
                take_opt(&args, "new_parent_id")?,
            )?;
            ok()
        }
        "indent_block" => {
            api.indent_block(take(&args, "doc_id")?, take(&args, "block_id")?)?;
            ok()
        }
        "outdent_block" => {
            api.outdent_block(take(&args, "doc_id")?, take(&args, "block_id")?)?;
            ok()
        }
        "set_block_color" => {
            api.set_block_color(
                take(&args, "doc_id")?,
                take(&args, "block_id")?,
                take_opt(&args, "color")?,
            )?;
            ok()
        }
        "set_block_background_color" => {
            api.set_block_background_color(
                take(&args, "doc_id")?,
                take(&args, "block_id")?,
                take_opt(&args, "background_color")?,
            )?;
            ok()
        }
        "set_block_text_direction" => {
            api.set_block_text_direction(
                take(&args, "doc_id")?,
                take(&args, "block_id")?,
                take_opt(&args, "text_direction")?,
            )?;
            ok()
        }

        // ── Trash ─────────────────────────────────────────────
        "list_deleted_documents" => json_of(api.list_deleted_documents()?),
        "restore_document" => {
            api.restore_document(take(&args, "id")?)?;
            ok()
        }
        "purge_document" => {
            api.purge_document(take(&args, "id")?)?;
            ok()
        }

        // ── Search ────────────────────────────────────────────
        "search_documents" => json_of(api.search_documents(take(&args, "query")?)?),
        "search_in_blocks" => json_of(api.search_in_blocks(take(&args, "query")?)?),
        "search_in_blocks_with_snippets" => json_of(api.search_in_blocks_with_snippets(
            take(&args, "query")?,
        )?),
        "search_databases" => json_of(api.search_databases(take(&args, "query")?)?),
        "search_folders" => json_of(api.search_folders(take(&args, "query")?)?),

        // ── Folders ───────────────────────────────────────────
        "create_folder" => {
            let meta = api.create_folder(
                take(&args, "name")?,
                take_opt(&args, "parent_id")?,
            )?;
            Ok(json!({ "id": meta.id }).to_string())
        }
        "list_folders" => json_of(api.list_folders()?),
        "get_folder" => json_of(api.get_folder(take(&args, "id")?)?),
        "rename_folder" => {
            api.rename_folder(take(&args, "id")?, take(&args, "new_name")?)?;
            ok()
        }
        "update_folder_icon" => {
            api.update_folder_icon(take(&args, "id")?, take_opt(&args, "icon")?)?;
            ok()
        }
        "delete_folder" => {
            api.delete_folder(take(&args, "id")?)?;
            ok()
        }
        "move_folder_to" => {
            api.move_folder_to(
                take(&args, "folder_id")?,
                take_opt(&args, "new_parent_id")?,
            )?;
            ok()
        }
        "move_document_to_folder" => {
            api.move_document_to_folder(
                take(&args, "doc_id")?,
                take_opt(&args, "folder_id")?,
            )?;
            ok()
        }
        "list_documents_in_folder" => json_of(api.list_documents_in_folder(
            take_opt(&args, "folder_id")?,
        )?),
        "list_deleted_folders" => json_of(api.list_deleted_folders()?),
        "restore_folder" => {
            api.restore_folder(take(&args, "id")?)?;
            ok()
        }
        "purge_folder" => {
            api.purge_folder(take(&args, "id")?)?;
            ok()
        }

        // ── Databases ─────────────────────────────────────────
        "list_databases" => json_of(api.list_databases()?),
        "get_database" => Ok(api.get_database_json(take(&args, "id")?)?),
        "update_database_title" => {
            api.update_database_title(take(&args, "id")?, take(&args, "new_title")?)?;
            ok()
        }
        "update_database_cover" => {
            api.update_database_cover(take(&args, "id")?, take_opt(&args, "cover")?)?;
            ok()
        }
        "update_database_icon" => {
            api.update_database_icon(take(&args, "id")?, take_opt(&args, "icon")?)?;
            ok()
        }
        "update_database_description" => {
            api.update_database_description(
                take(&args, "id")?,
                take(&args, "description")?,
            )?;
            ok()
        }
        "update_database_locked" => {
            api.update_database_locked(take(&args, "id")?, take(&args, "locked")?)?;
            ok()
        }
        "create_database" => Ok(json!({
            "id": api.create_database(take(&args, "title")?)?,
        }).to_string()),
        "delete_database" => {
            api.delete_database(take(&args, "id")?)?;
            ok()
        }
        "delete_all_databases" => Ok(json!({
            "deleted": api.delete_all_databases()?,
        }).to_string()),
        "list_deleted_databases" => json_of(api.list_deleted_databases()?),
        "restore_database" => {
            api.restore_database(take(&args, "id")?)?;
            ok()
        }
        "purge_database" => {
            api.purge_database(take(&args, "id")?)?;
            ok()
        }

        // ── Database entries ──────────────────────────────────
        "add_entry" => Ok(json!({
            "entry_id": api.add_entry(
                take(&args, "db_id")?,
                take(&args, "values_json")?,
            )?,
        }).to_string()),
        "attach_document_to_database" => Ok(json!({
            "entry_id": api.attach_document_to_database(
                take(&args, "db_id")?,
                take(&args, "doc_id")?,
                take(&args, "values_json")?,
            )?,
        }).to_string()),
        "update_entry" => {
            api.update_entry(
                take(&args, "db_id")?,
                take(&args, "entry_id")?,
                take(&args, "values_json")?,
            )?;
            ok()
        }
        "update_entry_published_at" => {
            api.update_entry_published_at(
                take(&args, "db_id")?,
                take(&args, "entry_id")?,
                take(&args, "new_published_at")?,
            )?;
            ok()
        }
        "delete_entry" => {
            api.delete_entry(take(&args, "db_id")?, take(&args, "entry_id")?)?;
            ok()
        }
        "restore_entry" => {
            api.restore_entry(take(&args, "db_id")?, take(&args, "entry_id")?)?;
            ok()
        }
        "purge_entry" => {
            api.purge_entry(take(&args, "db_id")?, take(&args, "entry_id")?)?;
            ok()
        }
        "list_deleted_entries" => Ok(api.list_deleted_entries_json(take(&args, "db_id")?)?),

        // ── Database properties + views ───────────────────────
        "add_property" => {
            api.add_property(take(&args, "db_id")?, take(&args, "property_json")?)?;
            ok()
        }
        "rename_property" => {
            api.rename_property(
                take(&args, "db_id")?,
                take(&args, "property_id")?,
                take(&args, "new_name")?,
            )?;
            ok()
        }
        "delete_property" => {
            api.delete_property(take(&args, "db_id")?, take(&args, "property_id")?)?;
            ok()
        }
        "add_view" => Ok(json!({
            "view_id": api.add_view(take(&args, "db_id")?, take(&args, "view_json")?)?,
        }).to_string()),
        "update_view" => {
            api.update_view(
                take(&args, "db_id")?,
                take(&args, "view_id")?,
                take(&args, "filters_json")?,
                take(&args, "sorts_json")?,
            )?;
            ok()
        }
        "set_view_sort" => {
            api.set_view_sort(
                take(&args, "db_id")?,
                take(&args, "view_id")?,
                take_opt(&args, "property_id")?,
                take(&args, "ascending")?,
            )?;
            ok()
        }
        "delete_view" => {
            api.delete_view(take(&args, "db_id")?, take(&args, "view_id")?)?;
            ok()
        }

        // ── Database queries ──────────────────────────────────
        "query_database" => Ok(api.query_database_json(
            take(&args, "db_id")?,
            take(&args, "view_id")?,
        )?),
        "query_database_with_rollups" => Ok(api.query_database_with_rollups_json(
            take(&args, "db_id")?,
            take(&args, "view_id")?,
        )?),
        "grouped_query_database" => Ok(api.grouped_query_database_json(
            take(&args, "db_id")?,
            take(&args, "view_id")?,
            take(&args, "group_by_property_id")?,
        )?),
        "column_aggregate_database" => Ok(api.column_aggregate_database_json(
            take(&args, "db_id")?,
            take(&args, "property_id")?,
            take(&args, "aggregate_json")?,
        )?),
        "search_database_entries" => Ok(api.search_database_entries_json(
            take(&args, "db_id")?,
            take(&args, "query")?,
        )?),

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
            serde_json::from_value(v.clone())
                .with_context(|| format!("invalid argument {key}"))?,
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
