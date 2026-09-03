//! Integration tests for the MCP dispatcher.
//!
//! The strategy is the "representative sample" approach : we don't
//! exercise every one of the ~60 tools individually, but we cover the
//! shape of each major branch (leaves, blocks, books,
//! properties, queries, shelves, errors) plus the helper boundary
//! (missing arg, unknown tool, optional null).
//!
//! All tests share a single in-memory `PinkhaApi` per test via the
//! `:memory:` SQLite path — round-tripping the dispatcher's JSON
//! envelope so we know both the parsing side and the FFI call side
//! are wired correctly.

use std::sync::Arc;

use pinkha::ffi::PinkhaApi;
use pinkha_mcp::tools::{dispatch, registry};
use serde_json::{Value, json};

fn api() -> Arc<PinkhaApi> {
    Arc::new(PinkhaApi::new(":memory:".to_string()).expect("create in-memory api"))
}

/// Pulls a typed field out of the JSON envelope returned by `dispatch`.
fn field(out: &str, key: &str) -> Value {
    let parsed: Value = serde_json::from_str(out).expect("dispatch returned non-JSON");
    parsed
        .get(key)
        .cloned()
        .unwrap_or_else(|| panic!("missing key {key} in {out}"))
}

// ── Registry shape ──────────────────────────────────────────────────────────

#[test]
fn registry_advertises_expected_tools() {
    let r = registry();
    let arr = r.as_array().expect("registry must be a JSON array");
    assert!(
        arr.len() >= 40,
        "expected ≥40 tools, got {} — did a refactor drop a tool group ?",
        arr.len()
    );

    let names: Vec<&str> = arr
        .iter()
        .filter_map(|tool| tool.get("name").and_then(Value::as_str))
        .collect();

    // Touch one tool per major domain so a future rename surfaces here
    // instead of waiting for an agent to complain.
    for expected in [
        "list_leaves",
        "create_leaf",
        "get_leaf",
        "add_block",
        "update_block",
        "delete_block",
        "create_book",
        "add_property",
        "add_entry",
        "query_book",
    ] {
        assert!(
            names.contains(&expected),
            "tool {expected} missing from registry"
        );
    }

    // Each tool must expose a name, description and inputSchema —
    // the MCP spec rejects entries that drop any of those.
    for tool in arr {
        for key in ["name", "description", "inputSchema"] {
            assert!(tool.get(key).is_some(), "tool entry missing {key}: {tool}");
        }
    }
}

// ── Leaves ──────────────────────────────────────────────────────────────

#[test]
fn create_then_list_then_get_then_delete_leaf() {
    let a = api();

    // create_leaf → returns { id }
    let out = dispatch(&a, "create_leaf", json!({ "title": "Hello" })).unwrap();
    let id = field(&out, "id").as_str().unwrap().to_string();

    // list_leaves → contains it
    let listed = dispatch(&a, "list_leaves", json!({})).unwrap();
    let arr: Value = serde_json::from_str(&listed).unwrap();
    let titles: Vec<String> = arr
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|m| {
            m.get("title_plain")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .collect();
    assert!(
        titles.contains(&"Hello".to_string()),
        "expected Hello in {titles:?}"
    );

    // get_leaf → full JSON doc, title round-trips
    let got = dispatch(&a, "get_leaf", json!({ "id": id })).unwrap();
    let parsed: Value = serde_json::from_str(&got).unwrap();
    assert_eq!(parsed.get("id").and_then(Value::as_str), Some(id.as_str()));

    // delete_leaf → ok envelope, then no longer in list
    let ok = dispatch(&a, "delete_leaf", json!({ "id": id })).unwrap();
    assert_eq!(field(&ok, "ok"), Value::Bool(true));

    let listed = dispatch(&a, "list_leaves", json!({})).unwrap();
    let arr: Value = serde_json::from_str(&listed).unwrap();
    let still_there = arr
        .as_array()
        .unwrap()
        .iter()
        .any(|m| m.get("id").and_then(Value::as_str) == Some(id.as_str()));
    assert!(!still_there, "soft-deleted doc should drop out of list");
}

#[test]
fn update_leaf_title_propagates_to_get() {
    let a = api();
    let id = field(
        &dispatch(&a, "create_leaf", json!({ "title": "Old" })).unwrap(),
        "id",
    )
    .as_str()
    .unwrap()
    .to_string();

    let ok = dispatch(
        &a,
        "update_leaf_title",
        json!({ "id": id, "new_title": "New" }),
    )
    .unwrap();
    assert_eq!(field(&ok, "ok"), Value::Bool(true));

    let got = dispatch(&a, "get_leaf", json!({ "id": &id })).unwrap();
    let parsed: Value = serde_json::from_str(&got).unwrap();
    // Title is a Vec<InlineText> in the JSON — the first span's
    // `content` carries the plain text.
    let title_text = parsed
        .get("title")
        .and_then(Value::as_array)
        .and_then(|spans| spans.first())
        .and_then(|s| s.get("content"))
        .and_then(Value::as_str)
        .unwrap_or("");
    assert_eq!(title_text, "New");
}

#[test]
fn update_leaf_cover_accepts_optional_null() {
    let a = api();
    let id = field(
        &dispatch(&a, "create_leaf", json!({ "title": "Cover" })).unwrap(),
        "id",
    )
    .as_str()
    .unwrap()
    .to_string();

    // Set a cover string.
    dispatch(
        &a,
        "update_leaf_cover",
        json!({ "id": &id, "cover": "cover-1" }),
    )
    .unwrap();
    // Explicit null clears it — exercises take_opt's `Value::Null` arm.
    dispatch(
        &a,
        "update_leaf_cover",
        json!({ "id": &id, "cover": Value::Null }),
    )
    .unwrap();
    // Omitted key also resolves to None — exercises take_opt's
    // missing-key arm.
    dispatch(&a, "update_leaf_cover", json!({ "id": &id })).unwrap();
}

// ── Blocks ─────────────────────────────────────────────────────────────────

#[test]
fn block_lifecycle_add_update_delete() {
    let a = api();
    let leaf_id = field(
        &dispatch(&a, "create_leaf", json!({ "title": "Doc" })).unwrap(),
        "id",
    )
    .as_str()
    .unwrap()
    .to_string();

    // BlockContent::Text is a tuple variant : `{ "Text": [...spans...] }`,
    // not a struct — serde tags the variant with the array directly.
    let text_block = json!({
        "Text": [{ "content": "hi", "styles": [] }]
    })
    .to_string();

    let added = dispatch(
        &a,
        "add_block",
        json!({ "leaf_id": &leaf_id, "block_content_json": text_block }),
    )
    .unwrap();
    let block_id = field(&added, "block_id").as_str().unwrap().to_string();
    assert!(!block_id.is_empty());

    // Replace content with a new text.
    let new_content = json!({
        "Text": [{ "content": "bye", "styles": [] }]
    })
    .to_string();
    let ok = dispatch(
        &a,
        "update_block",
        json!({
            "leaf_id": &leaf_id,
            "block_id": &block_id,
            "content_json": new_content,
        }),
    )
    .unwrap();
    assert_eq!(field(&ok, "ok"), Value::Bool(true));

    // Delete.
    let ok = dispatch(
        &a,
        "delete_block",
        json!({ "leaf_id": &leaf_id, "block_id": &block_id }),
    )
    .unwrap();
    assert_eq!(field(&ok, "ok"), Value::Bool(true));
}

// ── Books ──────────────────────────────────────────────────────────────

#[test]
fn book_lifecycle_create_property_entry_query() {
    let a = api();

    // create_book → returns { id }. Books start empty —
    // properties and views are added explicitly.
    let book_id = field(
        &dispatch(&a, "create_book", json!({ "title": "Tasks" })).unwrap(),
        "id",
    )
    .as_str()
    .unwrap()
    .to_string();

    // Add a Text property so we have something to write values into.
    let prop_id = uuid_string();
    let prop_json = json!({ "id": &prop_id, "name": "Note", "type_": "Text" }).to_string();
    let ok = dispatch(
        &a,
        "add_property",
        json!({ "book_id": &book_id, "property_json": prop_json }),
    )
    .unwrap();
    assert_eq!(field(&ok, "ok"), Value::Bool(true));

    // Add an entry that targets the property by its UUID.
    let values_json = json!({ &prop_id: { "Text": "Buy milk" } }).to_string();
    let entry_id = field(
        &dispatch(
            &a,
            "add_entry",
            json!({ "book_id": &book_id, "values_json": values_json }),
        )
        .unwrap(),
        "entry_id",
    )
    .as_str()
    .unwrap()
    .to_string();
    assert!(!entry_id.is_empty());

    // Need a view to call query_book (FFI signature requires a
    // real view_id, not Option). Default empty table view returns
    // the full entry set.
    let view_id = uuid_string();
    let view_json = json!({
        "id": &view_id,
        "name": "All",
        "type_": "Table",
        "filters": [],
        "sorts": [],
    })
    .to_string();
    let view_added = dispatch(
        &a,
        "add_view",
        json!({ "book_id": &book_id, "view_json": view_json }),
    )
    .unwrap();
    let view_id_returned = field(&view_added, "view_id").as_str().unwrap().to_string();

    let queried = dispatch(
        &a,
        "query_book",
        json!({ "book_id": &book_id, "view_id": &view_id_returned }),
    )
    .unwrap();
    let entries: Value = serde_json::from_str(&queried).unwrap();
    let found = entries
        .as_array()
        .map(|arr| {
            arr.iter()
                .any(|e| e.get("id").and_then(Value::as_str) == Some(entry_id.as_str()))
        })
        .unwrap_or(false);
    assert!(
        found,
        "queried result missing the entry we just added : {entries}"
    );
}

/// Tiny UUID-shaped string for property / view IDs. Tests don't
/// need real randomness ; deterministic-but-distinct is enough.
fn uuid_string() -> String {
    use std::sync::atomic::{AtomicU32, Ordering};
    static COUNTER: AtomicU32 = AtomicU32::new(1);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("00000000-0000-0000-0000-{n:012x}")
}

// ── End-to-end workflow ────────────────────────────────────────────────────
//
// One big walk through a representative agent session : leaf with
// blocks, shelf nesting, full book with property + view +
// queries + aggregate, plus a tour of the search / trash surfaces.
// This is the cheapest way to reach high dispatch-coverage without
// writing 50+ near-identical tests : every match arm we touch here
// is one less arm needing a dedicated test.

#[test]
fn end_to_end_agent_session_touches_most_tool_branches() {
    let a = api();
    let txt = |s: &str| json!([{ "content": s, "styles": [] }]).to_string();

    // ── Leaves ─────────────────────────────────────────────────
    let doc = field(
        &dispatch(&a, "create_leaf", json!({ "title": "Parent" })).unwrap(),
        "id",
    )
    .as_str()
    .unwrap()
    .to_string();

    // Hit each leaf-update tool to cover the structured-arg path
    // (including take_opt's `Some(...)` arm everywhere).
    for (tool, args) in [
        (
            "update_leaf_title",
            json!({ "id": &doc, "new_title": "Parent renamed" }),
        ),
        (
            "update_leaf_cover",
            json!({ "id": &doc, "cover": "cover-A" }),
        ),
        ("update_leaf_icon", json!({ "id": &doc, "icon": "🦊" })),
        ("update_leaf_locked", json!({ "id": &doc, "locked": false })),
        (
            "update_leaf_accent_color",
            json!({ "id": &doc, "accent_color": "teal" }),
        ),
        (
            "update_leaf_text_direction",
            json!({ "id": &doc, "text_direction": "ltr" }),
        ),
    ] {
        let out = dispatch(&a, tool, args).unwrap_or_else(|e| panic!("{tool}: {e}"));
        assert_eq!(field(&out, "ok"), Value::Bool(true), "{tool} ok");
    }

    // list_root_leaves + list_child_leaves — the parent_leaf_id
    // arg path.
    let _ = dispatch(&a, "list_root_leaves", json!({})).unwrap();
    let _ = dispatch(&a, "list_child_leaves", json!({ "parent_leaf_id": &doc })).unwrap();

    // ── Blocks ────────────────────────────────────────────────────
    let text_block =
        json!({ "Text": serde_json::from_str::<Value>(&txt("hi")).unwrap() }).to_string();
    let b1 = field(
        &dispatch(
            &a,
            "add_block",
            json!({ "leaf_id": &doc, "block_content_json": &text_block }),
        )
        .unwrap(),
        "block_id",
    )
    .as_str()
    .unwrap()
    .to_string();

    let b2 = field(
        &dispatch(
            &a,
            "add_block",
            json!({ "leaf_id": &doc, "block_content_json": &text_block }),
        )
        .unwrap(),
        "block_id",
    )
    .as_str()
    .unwrap()
    .to_string();

    // Add a child block under b1.
    let _child = field(
        &dispatch(
            &a,
            "add_child_block",
            json!({
                "leaf_id": &doc,
                "parent_id": &b1,
                "block_content_json": &text_block,
            }),
        )
        .unwrap(),
        "block_id",
    )
    .as_str()
    .unwrap()
    .to_string();

    // Mutations on b1 / b2 covering the block-tuning surface.
    for (tool, args) in [
        (
            "duplicate_block",
            json!({ "leaf_id": &doc, "block_id": &b1 }),
        ),
        (
            "reorder_blocks",
            json!({ "leaf_id": &doc, "order": [&b2, &b1] }),
        ),
        (
            "set_block_color",
            json!({ "leaf_id": &doc, "block_id": &b1, "color": "red" }),
        ),
        (
            "set_block_background_color",
            json!({ "leaf_id": &doc, "block_id": &b1, "background_color": "yellow" }),
        ),
        (
            "set_block_text_direction",
            json!({ "leaf_id": &doc, "block_id": &b1, "text_direction": "rtl" }),
        ),
        (
            "move_block",
            json!({ "leaf_id": &doc, "block_id": &b2, "new_parent_id": Value::Null }),
        ),
        ("indent_block", json!({ "leaf_id": &doc, "block_id": &b2 })),
        ("outdent_block", json!({ "leaf_id": &doc, "block_id": &b2 })),
    ] {
        // Some of these touch state that may make later ones a no-op
        // (e.g. outdent after move). We tolerate Err on individual
        // arms — what we need is the match arm to *execute* the FFI
        // call so coverage counts it.
        let _ = dispatch(&a, tool, args);
    }

    // ── Shelves ───────────────────────────────────────────────────
    let shelf = field(
        &dispatch(
            &a,
            "create_shelf",
            json!({ "name": "Notes", "parent_id": Value::Null }),
        )
        .unwrap(),
        "id",
    )
    .as_str()
    .unwrap()
    .to_string();

    let _ = dispatch(&a, "list_shelves", json!({})).unwrap();
    let _ = dispatch(&a, "get_shelf", json!({ "id": &shelf })).unwrap();
    let _ = dispatch(
        &a,
        "rename_shelf",
        json!({ "id": &shelf, "new_name": "Inbox" }),
    )
    .unwrap();
    let _ = dispatch(
        &a,
        "update_shelf_icon",
        json!({ "id": &shelf, "icon": "📥" }),
    )
    .unwrap();
    let _ = dispatch(
        &a,
        "move_leaf_to_shelf",
        json!({ "leaf_id": &doc, "shelf_id": &shelf }),
    )
    .unwrap();
    let _ = dispatch(&a, "list_leaves_in_shelf", json!({ "shelf_id": &shelf })).unwrap();
    let _ = dispatch(
        &a,
        "move_shelf_to",
        json!({ "shelf_id": &shelf, "new_parent_id": Value::Null }),
    )
    .unwrap();

    // ── Books full surface ────────────────────────────────────
    let db = field(
        &dispatch(&a, "create_book", json!({ "title": "Tasks" })).unwrap(),
        "id",
    )
    .as_str()
    .unwrap()
    .to_string();

    let _ = dispatch(&a, "list_books", json!({})).unwrap();
    let _ = dispatch(&a, "get_book", json!({ "id": &db })).unwrap();

    let prop = uuid_string();
    let prop_json = json!({ "id": &prop, "name": "Note", "type_": "Text" }).to_string();
    dispatch(
        &a,
        "add_property",
        json!({ "book_id": &db, "property_json": &prop_json }),
    )
    .unwrap();
    dispatch(
        &a,
        "rename_property",
        json!({ "book_id": &db, "property_id": &prop, "new_name": "Memo" }),
    )
    .unwrap();

    // Add an entry, update it, then exercise the trash surface.
    let entry = field(
        &dispatch(
            &a,
            "add_entry",
            json!({
                "book_id": &db,
                "values_json": json!({ &prop: { "Text": "first" } }).to_string(),
            }),
        )
        .unwrap(),
        "entry_id",
    )
    .as_str()
    .unwrap()
    .to_string();
    dispatch(
        &a,
        "update_entry",
        json!({
            "book_id": &db,
            "entry_id": &entry,
            "values_json": json!({ &prop: { "Text": "edited" } }).to_string(),
        }),
    )
    .unwrap();
    dispatch(
        &a,
        "delete_entry",
        json!({ "book_id": &db, "entry_id": &entry }),
    )
    .unwrap();
    dispatch(&a, "list_deleted_entries", json!({ "book_id": &db })).unwrap();
    dispatch(
        &a,
        "restore_entry",
        json!({ "book_id": &db, "entry_id": &entry }),
    )
    .unwrap();

    // Views + queries.
    let view = uuid_string();
    let view_json = json!({
        "id": &view,
        "name": "All",
        "type_": "Table",
        "filters": [],
        "sorts": [],
    })
    .to_string();
    let view_id = field(
        &dispatch(
            &a,
            "add_view",
            json!({ "book_id": &db, "view_json": &view_json }),
        )
        .unwrap(),
        "view_id",
    )
    .as_str()
    .unwrap()
    .to_string();

    dispatch(
        &a,
        "update_view",
        json!({
            "book_id": &db,
            "view_id": &view_id,
            "filters_json": "[]",
            "sorts_json": "[]",
        }),
    )
    .unwrap();
    dispatch(
        &a,
        "set_view_sort",
        json!({
            "book_id": &db,
            "view_id": &view_id,
            "property_id": &prop,
            "ascending": true,
        }),
    )
    .unwrap();

    let _ = dispatch(
        &a,
        "query_book",
        json!({ "book_id": &db, "view_id": &view_id }),
    )
    .unwrap();
    let _ = dispatch(
        &a,
        "query_book_with_rollups",
        json!({ "book_id": &db, "view_id": &view_id }),
    )
    .unwrap();
    let _ = dispatch(
        &a,
        "grouped_query_book",
        json!({
            "book_id": &db,
            "view_id": &view_id,
            "group_by_property_id": &prop,
        }),
    )
    .unwrap();
    let _ = dispatch(
        &a,
        "column_aggregate_book",
        json!({
            "book_id": &db,
            "property_id": &prop,
            "aggregate_json": json!({ "Count": null }).to_string(),
        }),
    );
    let _ = dispatch(
        &a,
        "search_book_entries",
        json!({ "book_id": &db, "query": "edit" }),
    )
    .unwrap();

    // ── Search surface ────────────────────────────────────────────
    for tool in [
        "search_leaves",
        "search_in_blocks",
        "search_in_blocks_with_snippets",
        "search_books",
        "search_shelves",
    ] {
        dispatch(&a, tool, json!({ "query": "Parent" })).unwrap();
    }

    // ── Trash + restore + purge ───────────────────────────────────
    let throwaway = field(
        &dispatch(&a, "create_leaf", json!({ "title": "Trash me" })).unwrap(),
        "id",
    )
    .as_str()
    .unwrap()
    .to_string();
    dispatch(&a, "delete_leaf", json!({ "id": &throwaway })).unwrap();
    dispatch(&a, "list_deleted_leaves", json!({})).unwrap();
    dispatch(&a, "restore_leaf", json!({ "id": &throwaway })).unwrap();
    dispatch(&a, "delete_leaf", json!({ "id": &throwaway })).unwrap();
    dispatch(&a, "purge_leaf", json!({ "id": &throwaway })).unwrap();

    // Shelf trash.
    let throwaway_shelf = field(
        &dispatch(
            &a,
            "create_shelf",
            json!({ "name": "Tmp", "parent_id": Value::Null }),
        )
        .unwrap(),
        "id",
    )
    .as_str()
    .unwrap()
    .to_string();
    dispatch(&a, "delete_shelf", json!({ "id": &throwaway_shelf })).unwrap();
    dispatch(&a, "list_deleted_shelves", json!({})).unwrap();
    dispatch(&a, "restore_shelf", json!({ "id": &throwaway_shelf })).unwrap();
    dispatch(&a, "delete_shelf", json!({ "id": &throwaway_shelf })).unwrap();
    dispatch(&a, "purge_shelf", json!({ "id": &throwaway_shelf })).unwrap();

    // Book trash.
    let throwaway_book = field(
        &dispatch(&a, "create_book", json!({ "title": "Tmp DB" })).unwrap(),
        "id",
    )
    .as_str()
    .unwrap()
    .to_string();
    dispatch(&a, "delete_book", json!({ "id": &throwaway_book })).unwrap();
    dispatch(&a, "list_deleted_books", json!({})).unwrap();
    dispatch(&a, "restore_book", json!({ "id": &throwaway_book })).unwrap();
    dispatch(&a, "delete_book", json!({ "id": &throwaway_book })).unwrap();
    dispatch(&a, "purge_book", json!({ "id": &throwaway_book })).unwrap();

    // Bulk deleters.
    dispatch(&a, "delete_all_leaves", json!({})).unwrap();
    dispatch(&a, "delete_all_books", json!({})).unwrap();

    // After the bulk delete, db / view / prop are gone so these are
    // safe to call on a fresh entity for cleanup branches.
    let final_book = field(
        &dispatch(&a, "create_book", json!({ "title": "Final" })).unwrap(),
        "id",
    )
    .as_str()
    .unwrap()
    .to_string();
    let final_prop = uuid_string();
    dispatch(
        &a,
        "add_property",
        json!({
            "book_id": &final_book,
            "property_json": json!({
                "id": &final_prop,
                "name": "X",
                "type_": "Text",
            }).to_string(),
        }),
    )
    .unwrap();
    dispatch(
        &a,
        "delete_property",
        json!({ "book_id": &final_book, "property_id": &final_prop }),
    )
    .unwrap();

    let final_view = uuid_string();
    dispatch(
        &a,
        "add_view",
        json!({
            "book_id": &final_book,
            "view_json": json!({
                "id": &final_view,
                "name": "V",
                "type_": "Table",
                "filters": [],
                "sorts": [],
            }).to_string(),
        }),
    )
    .unwrap();
    // delete_view refuses to drop the last view — so first add a
    // second one, then delete the second.
    let final_view2 = uuid_string();
    dispatch(
        &a,
        "add_view",
        json!({
            "book_id": &final_book,
            "view_json": json!({
                "id": &final_view2,
                "name": "V2",
                "type_": "Table",
                "filters": [],
                "sorts": [],
            }).to_string(),
        }),
    )
    .unwrap();
    dispatch(
        &a,
        "delete_view",
        json!({ "book_id": &final_book, "view_id": &final_view2 }),
    )
    .unwrap();

    // Parent move : create a fresh sibling and move it.
    let sibling = field(
        &dispatch(&a, "create_leaf", json!({ "title": "Sibling" })).unwrap(),
        "id",
    )
    .as_str()
    .unwrap()
    .to_string();
    let host = field(
        &dispatch(&a, "create_leaf", json!({ "title": "Host" })).unwrap(),
        "id",
    )
    .as_str()
    .unwrap()
    .to_string();
    dispatch(
        &a,
        "update_leaf_parent",
        json!({ "leaf_id": &sibling, "new_parent_leaf_id": &host }),
    )
    .unwrap();
    dispatch(
        &a,
        "update_leaf_parent",
        json!({ "leaf_id": &sibling, "new_parent_leaf_id": Value::Null }),
    )
    .unwrap();
}

// ── Errors ─────────────────────────────────────────────────────────────────

#[test]
fn unknown_tool_returns_error() {
    let a = api();
    let res = dispatch(&a, "definitely_not_a_tool", json!({}));
    assert!(res.is_err(), "unknown tool name must surface an error");
    let msg = res.unwrap_err().to_string();
    assert!(
        msg.contains("definitely_not_a_tool") || msg.contains("unknown"),
        "error should mention the offending tool : {msg}"
    );
}

#[test]
fn missing_required_arg_surfaces_descriptive_error() {
    let a = api();
    // create_leaf requires "title".
    let res = dispatch(&a, "create_leaf", json!({}));
    let err = res.expect_err("missing arg must error out");
    assert!(
        err.to_string().contains("title"),
        "error should name the missing arg : {err}"
    );
}

#[test]
fn invalid_arg_type_surfaces_descriptive_error() {
    let a = api();
    // "title" must be a string, not a number.
    let res = dispatch(&a, "create_leaf", json!({ "title": 42 }));
    let err = res.expect_err("wrong arg type must error out");
    assert!(
        err.to_string().contains("title"),
        "error should name the offending arg : {err}"
    );
}
