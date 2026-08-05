//! Comprehensive FFI integration tests — exercises every PinkhaApi method
//! (success + error paths) using an in-memory SQLite store.
//!
//! The imports (Notion HTTP, Bear, Craft) only have their input-validation
//! paths covered here; the actual extraction is exercised by the integration
//! tests in `integration_bear.rs`, `integration_craft.rs`, etc.

use pinkha::ffi::{PinkhaApi, PinkhaError};
use serde_json::json;
use uuid::Uuid;

fn api() -> PinkhaApi {
    PinkhaApi::new(":memory:".to_string()).expect("create in-memory api")
}

fn rand_path() -> String {
    std::env::temp_dir()
        .join(format!("pinkha-ffi-{}.db", Uuid::new_v4()))
        .to_str()
        .unwrap()
        .to_string()
}

// ── PinkhaApi::new ──────────────────────────────────────────────────────────

#[test]
fn new_in_memory_succeeds() {
    let _api = api();
}

#[test]
fn new_on_disk_persists_across_reopens() {
    let path = rand_path();
    let id = {
        let api = PinkhaApi::new(path.clone()).expect("open");
        api.create_leaf("Persisted".to_string())
            .expect("create")
    };
    let api2 = PinkhaApi::new(path.clone()).expect("reopen");
    let json = api2.get_leaf_json(id).expect("get");
    assert!(json.contains("Persisted"));
    let _ = std::fs::remove_file(&path);
}

#[test]
fn new_on_invalid_path_fails() {
    let result = PinkhaApi::new("/nonexistent_dir_xyz/pinkha.db".to_string());
    assert!(result.is_err());
}

// ── Leaves ───────────────────────────────────────────────────────────────

#[test]
fn create_and_get_leaf_roundtrip() {
    let a = api();
    let id = a.create_leaf("Hello".to_string()).expect("create");
    let json = a.get_leaf_json(id.clone()).expect("get");
    assert!(json.contains("Hello"));
    assert!(json.contains(&id));
}

#[test]
fn list_leaves_returns_created_leaves() {
    let a = api();
    a.create_leaf("A".to_string()).expect("a");
    a.create_leaf("B".to_string()).expect("b");
    let list = a.list_leaves().expect("list");
    assert_eq!(list.len(), 2);
}

#[test]
fn delete_leaf_removes_from_list() {
    let a = api();
    let id = a.create_leaf("Trash".to_string()).expect("create");
    a.delete_leaf(id.clone()).expect("delete");
    assert!(matches!(
        a.get_leaf_json(id).unwrap_err(),
        PinkhaError::NotFound { .. }
    ));
}

#[test]
fn delete_leaf_invalid_uuid_fails() {
    let a = api();
    let err = a.delete_leaf("not-a-uuid".to_string()).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn delete_all_leaves_returns_count() {
    let a = api();
    a.create_leaf("a".to_string()).unwrap();
    a.create_leaf("b".to_string()).unwrap();
    a.create_leaf("c".to_string()).unwrap();
    let n = a.delete_all_leaves().expect("delete all");
    assert_eq!(n, 3);
    assert_eq!(a.list_leaves().unwrap().len(), 0);
}

#[test]
fn delete_all_leaves_on_empty_is_zero() {
    let a = api();
    assert_eq!(a.delete_all_leaves().unwrap(), 0);
}

#[test]
fn update_leaf_title() {
    let a = api();
    let id = a.create_leaf("Old".to_string()).unwrap();
    a.update_leaf_title(id.clone(), "New".to_string())
        .expect("rename");
    let json = a.get_leaf_json(id).unwrap();
    assert!(json.contains("New"));
}

#[test]
fn update_leaf_title_too_large_fails() {
    let a = api();
    let id = a.create_leaf("X".to_string()).unwrap();
    let huge = "a".repeat(70 * 1024);
    let err = a.update_leaf_title(id, huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn update_leaf_cover_set_and_clear() {
    let a = api();
    let id = a.create_leaf("X".to_string()).unwrap();
    a.update_leaf_cover(id.clone(), Some("🌸".to_string()))
        .expect("set cover");
    let json = a.get_leaf_json(id.clone()).unwrap();
    assert!(json.contains("🌸"));
    a.update_leaf_cover(id.clone(), None)
        .expect("clear cover");
}

#[test]
fn create_leaf_title_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.create_leaf(huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn get_leaf_invalid_uuid_fails() {
    let a = api();
    let err = a.get_leaf_json("zzz".to_string()).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn get_leaf_not_found_fails() {
    let a = api();
    let err = a.get_leaf_json(Uuid::new_v4().to_string()).unwrap_err();
    assert!(matches!(err, PinkhaError::NotFound { .. }));
}

// ── Blocks ──────────────────────────────────────────────────────────────────

fn text_block_json(text: &str) -> String {
    json!({"Text": [{"content": text, "styles": []}]}).to_string()
}

#[test]
fn add_block_returns_uuid() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let block_id = a
        .add_block(doc, text_block_json("Hello"))
        .expect("add block");
    assert!(Uuid::parse_str(&block_id).is_ok());
}

#[test]
fn add_block_with_malformed_json_fails() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let err = a.add_block(doc, "not json".to_string()).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn add_block_oversized_json_fails() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let huge = "a".repeat(6 * 1024 * 1024);
    let err = a.add_block(doc, huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn update_block_replaces_content() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let block = a.add_block(doc.clone(), text_block_json("Old")).unwrap();
    a.update_block(doc.clone(), block.clone(), text_block_json("New"))
        .expect("update");
    let json = a.get_leaf_json(doc).unwrap();
    assert!(json.contains("New"));
}

#[test]
fn set_block_color_sets_and_clears() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let block = a.add_block(doc.clone(), text_block_json("c")).unwrap();
    a.set_block_color(doc.clone(), block.clone(), Some("red".to_string()))
        .expect("set color");
    a.set_block_color(doc, block, None).expect("clear color");
}

#[test]
fn set_block_color_too_large_fails() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let block = a.add_block(doc.clone(), text_block_json("c")).unwrap();
    let huge = "r".repeat(70 * 1024);
    let err = a.set_block_color(doc, block, Some(huge)).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn delete_block_removes_it() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let block = a.add_block(doc.clone(), text_block_json("x")).unwrap();
    a.delete_block(doc, block).expect("delete");
}

#[test]
fn reorder_blocks() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let b1 = a.add_block(doc.clone(), text_block_json("1")).unwrap();
    let b2 = a.add_block(doc.clone(), text_block_json("2")).unwrap();
    a.reorder_blocks(doc, vec![b2, b1]).expect("reorder");
}

#[test]
fn reorder_blocks_invalid_uuid_fails() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let err = a
        .reorder_blocks(doc, vec!["not-a-uuid".to_string()])
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn add_child_block() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let parent = a.add_block(doc.clone(), text_block_json("p")).unwrap();
    let child = a
        .add_child_block(doc, parent, text_block_json("c"))
        .expect("add child");
    assert!(Uuid::parse_str(&child).is_ok());
}

#[test]
fn reorder_child_blocks() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let parent = a.add_block(doc.clone(), text_block_json("p")).unwrap();
    let c1 = a
        .add_child_block(doc.clone(), parent.clone(), text_block_json("1"))
        .unwrap();
    let c2 = a
        .add_child_block(doc.clone(), parent.clone(), text_block_json("2"))
        .unwrap();
    a.reorder_child_blocks(doc, parent, vec![c2, c1])
        .expect("reorder");
}

#[test]
fn move_block_to_parent_and_root() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let parent = a.add_block(doc.clone(), text_block_json("p")).unwrap();
    let block = a.add_block(doc.clone(), text_block_json("b")).unwrap();
    a.move_block(doc.clone(), block.clone(), Some(parent.clone()))
        .expect("move to parent");
    a.move_block(doc, block, None).expect("move to root");
}

#[test]
fn move_block_invalid_parent_uuid_fails() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let block = a.add_block(doc.clone(), text_block_json("b")).unwrap();
    let err = a
        .move_block(doc, block, Some("not-a-uuid".to_string()))
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn indent_and_outdent_block() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let b1 = a.add_block(doc.clone(), text_block_json("1")).unwrap();
    let b2 = a.add_block(doc.clone(), text_block_json("2")).unwrap();
    a.indent_block(doc.clone(), b2.clone()).expect("indent");
    a.outdent_block(doc, b2).expect("outdent");
    let _ = b1;
}

#[test]
fn indent_first_block_fails() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let b1 = a.add_block(doc.clone(), text_block_json("only")).unwrap();
    let err = a.indent_block(doc, b1).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn outdent_root_block_fails() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let b = a.add_block(doc.clone(), text_block_json("x")).unwrap();
    let err = a.outdent_block(doc, b).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── Search ──────────────────────────────────────────────────────────────────

#[test]
fn search_leaves_by_title() {
    let a = api();
    a.create_leaf("Apple pie".to_string()).unwrap();
    a.create_leaf("Banana bread".to_string()).unwrap();
    a.create_leaf("Apple cake".to_string()).unwrap();
    let hits = a.search_leaves("apple".to_string()).unwrap();
    assert_eq!(hits.len(), 2);
}

#[test]
fn search_leaves_query_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.search_leaves(huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn search_in_blocks() {
    let a = api();
    let doc = a.create_leaf("Note".to_string()).unwrap();
    a.add_block(doc.clone(), text_block_json("needle in haystack"))
        .unwrap();
    let hits = a.search_in_blocks("needle".to_string()).unwrap();
    assert_eq!(hits.len(), 1);
}

#[test]
fn search_in_blocks_query_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.search_in_blocks(huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn search_in_blocks_with_snippets_returns_one_hit_per_block() {
    let a = api();
    let doc = a.create_leaf("Note".to_string()).unwrap();
    a.add_block(doc.clone(), text_block_json("Rust is great"))
        .unwrap();
    a.add_block(doc.clone(), text_block_json("Nothing here"))
        .unwrap();
    a.add_block(doc.clone(), text_block_json("More Rust love"))
        .unwrap();
    let hits = a
        .search_in_blocks_with_snippets("rust".to_string())
        .unwrap();
    assert_eq!(hits.len(), 2);
    let unique_blocks: std::collections::HashSet<_> =
        hits.iter().map(|h| h.block_id.clone()).collect();
    assert_eq!(unique_blocks.len(), 2);
    for hit in &hits {
        assert_eq!(hit.doc.id, doc);
        assert!(hit.snippet.to_lowercase().contains("rust"));
        // The exposed block_id is a valid UUID string Swift can parse.
        assert!(uuid::Uuid::parse_str(&hit.block_id).is_ok());
    }
}

#[test]
fn search_in_blocks_with_snippets_query_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.search_in_blocks_with_snippets(huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn search_books_by_title() {
    let a = api();
    a.create_book("Tasks Tracker".to_string()).unwrap();
    a.create_book("Recipes".to_string()).unwrap();
    let hits = a.search_books("tracker".to_string()).unwrap();
    assert_eq!(hits.len(), 1);
    assert!(hits[0].title_plain.contains("Tasks"));
}

#[test]
fn search_books_query_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.search_books(huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn search_shelves_by_name() {
    let a = api();
    a.create_shelf("Work Notes".to_string(), None).unwrap();
    a.create_shelf("Personal".to_string(), None).unwrap();
    let hits = a.search_shelves("work".to_string()).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].name, "Work Notes");
}

#[test]
fn search_shelves_query_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.search_shelves(huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── Books ───────────────────────────────────────────────────────────────

#[test]
fn create_and_list_books() {
    let a = api();
    a.create_book("Tasks".to_string()).unwrap();
    a.create_book("People".to_string()).unwrap();
    assert_eq!(a.list_books().unwrap().len(), 2);
}

#[test]
fn create_book_title_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.create_book(huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn get_book_returns_json() {
    let a = api();
    let id = a.create_book("Tasks".to_string()).unwrap();
    let json = a.get_book_json(id.clone()).unwrap();
    assert!(json.contains(&id));
}

#[test]
fn get_book_not_found() {
    let a = api();
    let err = a.get_book_json(Uuid::new_v4().to_string()).unwrap_err();
    assert!(matches!(err, PinkhaError::NotFound { .. }));
}

#[test]
fn delete_book() {
    let a = api();
    let id = a.create_book("Doomed".to_string()).unwrap();
    a.delete_book(id.clone()).unwrap();
    assert!(matches!(
        a.get_book_json(id).unwrap_err(),
        PinkhaError::NotFound { .. }
    ));
}

#[test]
fn delete_all_books_returns_count() {
    let a = api();
    a.create_book("a".to_string()).unwrap();
    a.create_book("b".to_string()).unwrap();
    assert_eq!(a.delete_all_books().unwrap(), 2);
    assert_eq!(a.list_books().unwrap().len(), 0);
}

// ── Properties + entries + views ───────────────────────────────────────────

fn make_text_property(name: &str) -> String {
    json!({
        "id": Uuid::new_v4().to_string(),
        "name": name,
        "type_": "Text"
    })
    .to_string()
}

fn make_title_property(name: &str) -> (String, String) {
    let id = Uuid::new_v4();
    let json = json!({
        "id": id.to_string(),
        "name": name,
        "type_": "Title"
    })
    .to_string();
    (id.to_string(), json)
}

#[test]
fn add_property_to_book() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    a.add_property(db.clone(), make_text_property("Notes"))
        .unwrap();
    let json = a.get_book_json(db).unwrap();
    assert!(json.contains("Notes"));
}

#[test]
fn add_property_invalid_book_uuid_fails() {
    let a = api();
    let err = a
        .add_property("not-uuid".to_string(), make_text_property("X"))
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn rename_property_changes_name() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let prop_id = Uuid::new_v4().to_string();
    let prop_json = json!({"id": prop_id, "name": "Old", "type_": "Text"}).to_string();
    a.add_property(db.clone(), prop_json).unwrap();
    a.rename_property(db.clone(), prop_id, "New".to_string())
        .unwrap();
    let json = a.get_book_json(db).unwrap();
    assert!(json.contains("New"));
}

#[test]
fn rename_property_too_large_fails() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let prop_id = Uuid::new_v4().to_string();
    let huge = "a".repeat(70 * 1024);
    let err = a.rename_property(db, prop_id, huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn delete_property_clears_values() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let prop_id = Uuid::new_v4().to_string();
    let prop_json = json!({"id": prop_id, "name": "C", "type_": "Text"}).to_string();
    a.add_property(db.clone(), prop_json).unwrap();
    a.delete_property(db, prop_id).unwrap();
}

#[test]
fn add_entry_to_book() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let prop_id = Uuid::new_v4().to_string();
    let prop_json = json!({"id": prop_id, "name": "Note", "type_": "Text"}).to_string();
    a.add_property(db.clone(), prop_json).unwrap();
    let values = json!({prop_id: {"Text": "Hello"}}).to_string();
    let entry = a.add_entry(db, values).unwrap();
    assert!(Uuid::parse_str(&entry).is_ok());
}

#[test]
fn add_entry_with_malformed_json_fails() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let err = a.add_entry(db, "broken".to_string()).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn update_entry_propagates_title_when_linked() {
    let a = api();
    let db = a.create_book("Tasks".to_string()).unwrap();
    let (title_id, title_prop_json) = make_title_property("Name");
    a.add_property(db.clone(), title_prop_json).unwrap();
    let initial_values = json!({
        title_id.clone(): {"Title": [{"content": "Old", "styles": []}]}
    })
    .to_string();
    let entry = a.add_entry(db.clone(), initial_values).unwrap();
    let new_values = json!({
        title_id: {"Title": [{"content": "New", "styles": []}]}
    })
    .to_string();
    a.update_entry(db, entry, new_values).unwrap();
}

#[test]
fn delete_entry() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let entry = a.add_entry(db.clone(), "{}".to_string()).unwrap();
    a.delete_entry(db, entry).unwrap();
}

fn make_view(name: &str) -> (String, String) {
    let id = Uuid::new_v4();
    let json = json!({
        "id": id.to_string(),
        "name": name,
        "type_": "Table",
        "filters": [],
        "sorts": []
    })
    .to_string();
    (id.to_string(), json)
}

#[test]
fn add_and_query_view() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let (_, view_json) = make_view("Default");
    let view = a.add_view(db.clone(), view_json).unwrap();
    let entries_json = a.query_book_json(db, view).unwrap();
    assert_eq!(entries_json, "[]");
}

#[test]
fn update_view_filters_and_sorts() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let (_, view_json) = make_view("V");
    let view = a.add_view(db.clone(), view_json).unwrap();
    a.update_view(db, view, "[]".to_string(), "[]".to_string())
        .unwrap();
}

#[test]
fn set_view_sort_with_and_without_property() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let (_, view_json) = make_view("V");
    let view = a.add_view(db.clone(), view_json).unwrap();
    let prop = Uuid::new_v4().to_string();
    a.set_view_sort(db.clone(), view.clone(), Some(prop), true)
        .unwrap();
    a.set_view_sort(db, view, None, false).unwrap();
}

#[test]
fn set_view_sort_invalid_property_uuid_fails() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let (_, view_json) = make_view("V");
    let view = a.add_view(db.clone(), view_json).unwrap();
    let err = a
        .set_view_sort(db, view, Some("nope".to_string()), true)
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn delete_view() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let (_, v1) = make_view("V1");
    let view1 = a.add_view(db.clone(), v1).unwrap();
    let (_, v2) = make_view("V2");
    let _ = a.add_view(db.clone(), v2).unwrap();
    a.delete_view(db, view1).unwrap();
}

#[test]
fn query_book_with_rollups() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let (_, view_json) = make_view("V");
    let view = a.add_view(db.clone(), view_json).unwrap();
    let entries_json = a.query_book_with_rollups_json(db, view).unwrap();
    assert_eq!(entries_json, "[]");
}

#[test]
fn grouped_query_book() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let prop_id = Uuid::new_v4();
    let prop_json = json!({
        "id": prop_id.to_string(),
        "name": "Status",
        "type_": {"Selection": ["Done", "Todo"]}
    })
    .to_string();
    a.add_property(db.clone(), prop_json).unwrap();
    let (_, view_json) = make_view("V");
    let view = a.add_view(db.clone(), view_json).unwrap();
    let groups = a
        .grouped_query_book_json(db, view, prop_id.to_string())
        .unwrap();
    assert!(groups.starts_with('['));
}

#[test]
fn column_aggregate_count() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let prop_id = Uuid::new_v4().to_string();
    let prop_json = json!({"id": prop_id, "name": "N", "type_": "Number"}).to_string();
    a.add_property(db.clone(), prop_json.clone()).unwrap();
    let result = a
        .column_aggregate_book_json(db, prop_id, json!("Count").to_string())
        .unwrap();
    assert!(result.contains("Number"));
}

#[test]
fn column_aggregate_invalid_json_fails() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let err = a
        .column_aggregate_book_json(db, Uuid::new_v4().to_string(), "garbage".to_string())
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn search_book_entries() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let prop_id = Uuid::new_v4().to_string();
    let prop_json = json!({"id": prop_id, "name": "Note", "type_": "Text"}).to_string();
    a.add_property(db.clone(), prop_json).unwrap();
    let values = json!({prop_id: {"Text": "needle"}}).to_string();
    a.add_entry(db.clone(), values).unwrap();
    let json = a
        .search_book_entries_json(db, "needle".to_string())
        .unwrap();
    assert!(json.contains("needle"));
}

#[test]
fn search_book_entries_query_too_large_fails() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let huge = "a".repeat(70 * 1024);
    let err = a.search_book_entries_json(db, huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── Shelves ─────────────────────────────────────────────────────────────────

#[test]
fn create_and_get_shelf() {
    let a = api();
    let f = a.create_shelf("Inbox".to_string(), None).unwrap();
    assert_eq!(f.name, "Inbox");
    assert!(f.parent_id.is_none());
    let loaded = a.get_shelf(f.id.clone()).unwrap();
    assert_eq!(loaded.name, "Inbox");
}

#[test]
fn create_nested_shelf() {
    let a = api();
    let parent = a.create_shelf("Parent".to_string(), None).unwrap();
    let child = a
        .create_shelf("Child".to_string(), Some(parent.id.clone()))
        .unwrap();
    assert_eq!(child.parent_id.as_deref(), Some(parent.id.as_str()));
}

#[test]
fn create_shelf_name_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.create_shelf(huge, None).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn create_shelf_with_invalid_parent_uuid_fails() {
    let a = api();
    let err = a
        .create_shelf("X".to_string(), Some("not-uuid".to_string()))
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn update_shelf_icon_sets_and_clears() {
    let a = api();
    let shelf = a.create_shelf("Work".to_string(), None).unwrap();
    let id = shelf.id.clone();
    a.update_shelf_icon(id.clone(), Some("📁".to_string()))
        .unwrap();
    let shelves = a.list_shelves().unwrap();
    assert_eq!(
        shelves.iter().find(|f| f.id == id).unwrap().icon.as_deref(),
        Some("📁")
    );
    a.update_shelf_icon(id.clone(), None).unwrap();
    let shelves = a.list_shelves().unwrap();
    assert!(shelves.iter().find(|f| f.id == id).unwrap().icon.is_none());
}

#[test]
fn update_shelf_icon_with_invalid_uuid_fails() {
    let a = api();
    let err = a
        .update_shelf_icon("not-uuid".to_string(), Some("📁".to_string()))
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn delete_all_shelves_returns_count_and_clears() {
    let a = api();
    a.create_shelf("A".to_string(), None).unwrap();
    a.create_shelf("B".to_string(), None).unwrap();
    a.create_shelf("C".to_string(), None).unwrap();
    let n = a.delete_all_shelves().unwrap();
    assert_eq!(n, 3);
    assert!(a.list_shelves().unwrap().is_empty());
}

// ── Doc-in-doc hierarchy ────────────────────────────────────────────────────

#[test]
fn update_leaf_parent_then_list_root_and_children() {
    let a = api();
    let parent = a.create_leaf("Parent".to_string()).unwrap();
    let child = a.create_leaf("Child".to_string()).unwrap();
    a.update_leaf_parent(child.clone(), Some(parent.clone()))
        .unwrap();

    let roots = a.list_root_leaves().unwrap();
    assert!(roots.iter().any(|d| d.id == parent));
    assert!(!roots.iter().any(|d| d.id == child));

    let children = a.list_child_leaves(parent.clone()).unwrap();
    assert_eq!(children.len(), 1);
    assert_eq!(children[0].id, child);

    // Promoting the child back to root removes it from the parent's children.
    a.update_leaf_parent(child.clone(), None).unwrap();
    assert!(a.list_child_leaves(parent).unwrap().is_empty());
    assert!(
        a.list_root_leaves()
            .unwrap()
            .iter()
            .any(|d| d.id == child)
    );
}

#[test]
fn update_leaf_parent_rejects_self() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let err = a
        .update_leaf_parent(doc.clone(), Some(doc))
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn update_leaf_parent_rejects_cycle() {
    let a = api();
    let a_id = a.create_leaf("A".to_string()).unwrap();
    let b_id = a.create_leaf("B".to_string()).unwrap();
    // B is a child of A.
    a.update_leaf_parent(b_id.clone(), Some(a_id.clone()))
        .unwrap();
    // Trying to make A a child of B would create a cycle.
    let err = a.update_leaf_parent(a_id, Some(b_id)).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn update_leaf_parent_with_invalid_uuid_fails() {
    let a = api();
    let err = a
        .update_leaf_parent("not-uuid".to_string(), None)
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn list_child_leaves_with_invalid_uuid_fails() {
    let a = api();
    let err = a.list_child_leaves("not-uuid".to_string()).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn list_shelves_returns_all() {
    let a = api();
    a.create_shelf("Alpha".to_string(), None).unwrap();
    a.create_shelf("Beta".to_string(), None).unwrap();
    assert_eq!(a.list_shelves().unwrap().len(), 2);
}

#[test]
fn rename_shelf_changes_name() {
    let a = api();
    let f = a.create_shelf("Old".to_string(), None).unwrap();
    a.rename_shelf(f.id.clone(), "New".to_string()).unwrap();
    assert_eq!(a.get_shelf(f.id).unwrap().name, "New");
}

#[test]
fn rename_shelf_name_too_large_fails() {
    let a = api();
    let f = a.create_shelf("X".to_string(), None).unwrap();
    let huge = "a".repeat(70 * 1024);
    let err = a.rename_shelf(f.id, huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn delete_shelf() {
    let a = api();
    let f = a.create_shelf("X".to_string(), None).unwrap();
    a.delete_shelf(f.id.clone()).unwrap();
    let err = a.get_shelf(f.id).unwrap_err();
    assert!(matches!(err, PinkhaError::NotFound { .. }));
}

#[test]
fn move_shelf_to_new_parent() {
    let a = api();
    let a_shelf = a.create_shelf("A".to_string(), None).unwrap();
    let b = a.create_shelf("B".to_string(), None).unwrap();
    a.move_shelf_to(a_shelf.id.clone(), Some(b.id.clone()))
        .unwrap();
    assert_eq!(
        a.get_shelf(a_shelf.id).unwrap().parent_id.as_deref(),
        Some(b.id.as_str())
    );
}

#[test]
fn move_shelf_to_root() {
    let a = api();
    let parent = a.create_shelf("P".to_string(), None).unwrap();
    let child = a
        .create_shelf("C".to_string(), Some(parent.id.clone()))
        .unwrap();
    a.move_shelf_to(child.id.clone(), None).unwrap();
    assert!(a.get_shelf(child.id).unwrap().parent_id.is_none());
}

#[test]
fn move_shelf_with_invalid_uuid_fails() {
    let a = api();
    let err = a.move_shelf_to("nope".to_string(), None).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn move_leaf_to_shelf_and_list() {
    let a = api();
    let f = a.create_shelf("Box".to_string(), None).unwrap();
    let doc = a.create_leaf("Note".to_string()).unwrap();
    a.move_leaf_to_shelf(doc.clone(), Some(f.id.clone()))
        .unwrap();
    let in_shelf = a.list_leaves_in_shelf(Some(f.id)).unwrap();
    assert_eq!(in_shelf.len(), 1);
    let at_root = a.list_leaves_in_shelf(None).unwrap();
    assert_eq!(at_root.len(), 0);
    a.move_leaf_to_shelf(doc, None).unwrap();
    let at_root = a.list_leaves_in_shelf(None).unwrap();
    assert_eq!(at_root.len(), 1);
}

#[test]
fn list_leaves_in_shelf_with_invalid_uuid_fails() {
    let a = api();
    let err = a
        .list_leaves_in_shelf(Some("garbage".to_string()))
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── Imports — validation paths only ────────────────────────────────────────

#[test]
fn import_from_notion_with_empty_token_or_book_id_does_not_panic() {
    let a = api();
    // Network call will fail fast; we just want to make sure validation
    // wrapping does not panic and that an error is returned.
    let result = a.import_from_notion(
        "invalid_token".to_string(),
        "00000000-0000-0000-0000-000000000000".to_string(),
        None,
    );
    assert!(result.is_err());
}

#[test]
fn import_from_notion_token_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a
        .import_from_notion(huge, "db".to_string(), None)
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn import_from_notion_book_id_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a
        .import_from_notion("tok".to_string(), huge, None)
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[tokio::test]
async fn import_from_bear_path_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.import_from_bear(huge).await.unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[tokio::test]
async fn import_from_bear_with_missing_file_fails() {
    let a = api();
    let err = a
        .import_from_bear("/nonexistent_path_xyz/bear.db".to_string())
        .await
        .unwrap_err();
    let _ = err;
}

#[tokio::test]
async fn import_from_craft_path_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.import_from_craft(huge).await.unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[tokio::test]
async fn import_from_craft_with_missing_file_fails() {
    let a = api();
    let err = a
        .import_from_craft("/nonexistent_path_xyz/craft.realm".to_string())
        .await
        .unwrap_err();
    let _ = err;
}

#[tokio::test]
async fn import_from_craft_textbundle_path_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.import_from_craft_textbundle(huge).await.unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[tokio::test]
async fn import_from_craft_textbundle_with_missing_dir_returns_error() {
    let a = api();
    let err = a
        .import_from_craft_textbundle("/nonexistent_dir_xyz".to_string())
        .await
        .expect_err("missing dir should be an error");
    // The textbundle extractor now validates the path up-front and
    // surfaces a storage error with a descriptive message.
    assert!(matches!(err, PinkhaError::Storage { .. }));
}

#[tokio::test]
async fn import_from_craft_textbundle_with_file_path_returns_error() {
    let a = api();
    // Pass a path that exists but is not a directory.
    let file_path = std::env::temp_dir().join(format!("pinkha-test-{}.txt", Uuid::new_v4()));
    std::fs::write(&file_path, b"not a directory").expect("write");
    let err = a
        .import_from_craft_textbundle(file_path.to_string_lossy().to_string())
        .await
        .expect_err("file path should be an error");
    assert!(matches!(err, PinkhaError::Storage { .. }));
    let _ = std::fs::remove_file(&file_path);
}

#[tokio::test]
async fn import_from_craft_textbundle_with_empty_dir_succeeds_with_zero_leaves() {
    let a = api();
    // Existing, empty directory → no error, just 0 imports.
    let dir = std::env::temp_dir().join(format!("pinkha-test-empty-{}", Uuid::new_v4()));
    std::fs::create_dir(&dir).expect("mkdir");
    let result = a
        .import_from_craft_textbundle(dir.to_string_lossy().to_string())
        .await
        .expect("empty dir should succeed");
    assert_eq!(result.leaves, 0);
    let _ = std::fs::remove_dir(&dir);
}

#[tokio::test]
async fn import_from_craft_combined_path_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a
        .import_from_craft_combined(huge, "x".to_string())
        .await
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[tokio::test]
async fn import_from_craft_combined_textbundle_root_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a
        .import_from_craft_combined("ok".to_string(), huge)
        .await
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── PinkhaError surfaces ───────────────────────────────────────────────────

#[test]
fn error_display_renders_english_messages() {
    assert!(format!("{}", PinkhaError::NotFound { id: "abc".into() }).contains("not found"));
    assert!(
        format!("{}", PinkhaError::InvalidOperation { detail: "x".into() }).contains("invalid")
    );
    assert!(format!("{}", PinkhaError::Storage { detail: "x".into() }).contains("storage"));
}

#[test]
fn error_debug_does_not_panic() {
    let e = PinkhaError::NotFound { id: "abc".into() };
    let _ = format!("{:?}", e);
}

// ── Shelf metadata round-trip ─────────────────────────────────────────────

#[test]
fn shelf_metadata_includes_timestamps() {
    let a = api();
    let f = a.create_shelf("X".to_string(), None).unwrap();
    assert!(!f.created_at.is_empty());
    assert!(!f.updated_at.is_empty());
}

#[test]
fn leaf_metadata_includes_timestamps_and_shelf() {
    let a = api();
    let shelf = a.create_shelf("F".to_string(), None).unwrap();
    let leaf_id = a.create_leaf("D".to_string()).unwrap();
    a.move_leaf_to_shelf(leaf_id.clone(), Some(shelf.id.clone()))
        .unwrap();
    let in_shelf = a.list_leaves_in_shelf(Some(shelf.id.clone())).unwrap();
    assert_eq!(in_shelf.len(), 1);
    let meta = &in_shelf[0];
    assert!(!meta.updated_at.is_empty());
    assert!(!meta.created_at.is_empty());
    assert_eq!(meta.shelf_id.as_deref(), Some(shelf.id.as_str()));
}

#[test]
fn book_metadata_includes_timestamps() {
    let a = api();
    a.create_book("X".to_string()).unwrap();
    let list = a.list_books().unwrap();
    assert_eq!(list.len(), 1);
    let meta = &list[0];
    assert!(!meta.updated_at.is_empty());
    assert!(!meta.created_at.is_empty());
}

// ── Leaf chrome: locked / theme / published_at ──────────────────────────

#[test]
fn update_leaf_locked_roundtrip() {
    let a = api();
    let id = a.create_leaf("Lockable".to_string()).unwrap();
    a.update_leaf_locked(id.clone(), true).unwrap();
    assert!(
        a.get_leaf_json(id.clone())
            .unwrap()
            .contains("\"locked\":true")
    );
    a.update_leaf_locked(id.clone(), false).unwrap();
    assert!(
        a.get_leaf_json(id)
            .unwrap()
            .contains("\"locked\":false")
    );
}

#[test]
fn update_leaf_theme_set_and_clear() {
    let a = api();
    let id = a.create_leaf("Themed".to_string()).unwrap();
    a.update_leaf_theme(id.clone(), Some("dark".to_string()))
        .unwrap();
    assert!(a.get_leaf_json(id.clone()).unwrap().contains("dark"));
    a.update_leaf_theme(id.clone(), None).unwrap();
    assert!(!a.get_leaf_json(id).unwrap().contains("\"dark\""));
}

#[test]
fn update_leaf_published_at_overrides_and_resets() {
    let a = api();
    let id = a.create_leaf("Dated".to_string()).unwrap();
    a.update_leaf_published_at(id.clone(), "2026-01-15T10:00:00Z".to_string())
        .unwrap();
    let meta = a
        .list_leaves()
        .unwrap()
        .into_iter()
        .find(|m| m.id == id)
        .unwrap();
    assert_eq!(meta.published_at, "2026-01-15T10:00:00Z");
    // Empty string = reset to "follow created_at" — resolved against the
    // row's real creation timestamp, not the save time.
    a.update_leaf_published_at(id.clone(), String::new())
        .unwrap();
    let meta = a
        .list_leaves()
        .unwrap()
        .into_iter()
        .find(|m| m.id == id)
        .unwrap();
    assert_eq!(meta.published_at, meta.created_at);
}

#[test]
fn update_leaf_published_at_rejects_oversized_value() {
    let a = api();
    let id = a.create_leaf("Doc".to_string()).unwrap();
    let err = a
        .update_leaf_published_at(id, "x".repeat(65))
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── Book chrome: cover / icon / description / locked ────────────────────

#[test]
fn update_book_cover_icon_description_roundtrip() {
    let a = api();
    let db = a.create_book("Styled".to_string()).unwrap();
    a.update_book_cover(db.clone(), Some("cover.nebula".to_string()))
        .unwrap();
    a.update_book_icon(db.clone(), Some("📚".to_string()))
        .unwrap();
    a.update_book_description(db.clone(), "A described base".to_string())
        .unwrap();
    let json = a.get_book_json(db.clone()).unwrap();
    assert!(json.contains("cover.nebula"));
    assert!(json.contains("📚"));
    assert!(json.contains("A described base"));
    // Clearing.
    a.update_book_cover(db.clone(), None).unwrap();
    a.update_book_icon(db.clone(), None).unwrap();
    a.update_book_description(db.clone(), String::new())
        .unwrap();
    let json = a.get_book_json(db).unwrap();
    assert!(!json.contains("cover.nebula"));
    assert!(!json.contains("📚"));
    assert!(!json.contains("A described base"));
}

#[test]
fn update_book_locked_roundtrip() {
    let a = api();
    let db = a.create_book("Lockable".to_string()).unwrap();
    a.update_book_locked(db.clone(), true).unwrap();
    assert!(
        a.get_book_json(db.clone())
            .unwrap()
            .contains("\"locked\":true")
    );
    a.update_book_locked(db.clone(), false).unwrap();
    assert!(
        a.get_book_json(db)
            .unwrap()
            .contains("\"locked\":false")
    );
}

#[test]
fn update_book_locked_invalid_uuid_fails() {
    let a = api();
    let err = a
        .update_book_locked("not-a-uuid".to_string(), true)
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── attach_leaf_to_book ──────────────────────────────────────────────

#[test]
fn attach_leaf_links_entry_to_leaf() {
    let a = api();
    let db = a.create_book("Tracker".to_string()).unwrap();
    let doc = a.create_leaf("Existing note".to_string()).unwrap();
    let entry_id = a
        .attach_leaf_to_book(db.clone(), doc.clone(), "{}".to_string())
        .unwrap();
    let json = a.get_book_json(db).unwrap();
    let value: serde_json::Value = serde_json::from_str(&json).unwrap();
    let entries = value["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["id"], entry_id);
    assert_eq!(entries[0]["leaf_id"], doc);
}

#[test]
fn attach_leaf_invalid_uuids_fail() {
    let a = api();
    let err = a
        .attach_leaf_to_book("bad".to_string(), "bad".to_string(), "{}".to_string())
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── update_entry_published_at ────────────────────────────────────────────────

#[test]
fn update_entry_published_at_overrides_and_resets() {
    let a = api();
    let db = a.create_book("Journal".to_string()).unwrap();
    let entry = a.add_entry(db.clone(), "{}".to_string()).unwrap();
    a.update_entry_published_at(
        db.clone(),
        entry.clone(),
        "2026-02-01T08:00:00Z".to_string(),
    )
    .unwrap();
    assert!(
        a.get_book_json(db.clone())
            .unwrap()
            .contains("2026-02-01T08:00:00Z")
    );
    a.update_entry_published_at(db.clone(), entry, String::new())
        .unwrap();
    assert!(
        !a.get_book_json(db)
            .unwrap()
            .contains("2026-02-01T08:00:00Z")
    );
}

#[test]
fn update_entry_published_at_rejects_oversized_value() {
    let a = api();
    let db = a.create_book("Journal".to_string()).unwrap();
    let entry = a.add_entry(db.clone(), "{}".to_string()).unwrap();
    let err = a
        .update_entry_published_at(db, entry, "x".repeat(65))
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn update_entry_published_at_unknown_entry_fails() {
    let a = api();
    let db = a.create_book("Journal".to_string()).unwrap();
    let err = a
        .update_entry_published_at(db, Uuid::new_v4().to_string(), "2026-01-01".to_string())
        .unwrap_err();
    assert!(matches!(err, PinkhaError::NotFound { .. }));
}

// ── set_view_date_sort ───────────────────────────────────────────────────────

fn first_view_id(a: &PinkhaApi, db: &str) -> String {
    let json = a.get_book_json(db.to_string()).unwrap();
    let value: serde_json::Value = serde_json::from_str(&json).unwrap();
    value["views"][0]["id"].as_str().unwrap().to_string()
}

#[test]
fn set_view_date_sort_created_and_published() {
    let a = api();
    let db = a.create_book("Sorted".to_string()).unwrap();
    let view = first_view_id(&a, &db);
    a.set_view_date_sort(db.clone(), view.clone(), "published".to_string(), true)
        .unwrap();
    assert!(
        a.get_book_json(db.clone())
            .unwrap()
            .contains("\"Published\"")
    );
    a.set_view_date_sort(db.clone(), view, "created".to_string(), false)
        .unwrap();
    let json = a.get_book_json(db).unwrap();
    assert!(json.contains("\"Created\""));
    assert!(json.contains("\"Descending\""));
}

#[test]
fn set_view_date_sort_rejects_unknown_kind() {
    let a = api();
    let db = a.create_book("Sorted".to_string()).unwrap();
    let view = first_view_id(&a, &db);
    let err = a
        .set_view_date_sort(db, view, "modified".to_string(), true)
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn set_view_date_sort_unknown_view_fails() {
    let a = api();
    let db = a.create_book("Sorted".to_string()).unwrap();
    let err = a
        .set_view_date_sort(db, Uuid::new_v4().to_string(), "created".to_string(), true)
        .unwrap_err();
    assert!(matches!(err, PinkhaError::NotFound { .. }));
}

// ── Entry trash: delete / restore / purge ────────────────────────────────────

#[test]
fn entry_delete_restore_purge_cycle() {
    let a = api();
    let db = a.create_book("Rows".to_string()).unwrap();
    let entry = a.add_entry(db.clone(), "{}".to_string()).unwrap();

    a.delete_entry(db.clone(), entry.clone()).unwrap();
    assert!(
        a.list_deleted_entries_json(db.clone())
            .unwrap()
            .contains(&entry)
    );

    a.restore_entry(db.clone(), entry.clone()).unwrap();
    assert!(
        !a.list_deleted_entries_json(db.clone())
            .unwrap()
            .contains(&entry)
    );
    assert!(a.get_book_json(db.clone()).unwrap().contains(&entry));

    a.delete_entry(db.clone(), entry.clone()).unwrap();
    a.purge_entry(db.clone(), entry.clone()).unwrap();
    assert!(
        !a.list_deleted_entries_json(db.clone())
            .unwrap()
            .contains(&entry)
    );
    assert!(!a.get_book_json(db).unwrap().contains(&entry));
}

// ── duplicate_block ──────────────────────────────────────────────────────────

#[test]
fn duplicate_block_inserts_clone_after_original() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let block = a
        .add_block(
            doc.clone(),
            json!({"Text": [{"content": "original", "styles": []}]}).to_string(),
        )
        .unwrap();
    let clone = a.duplicate_block(doc.clone(), block.clone()).unwrap();
    assert_ne!(clone, block);
    let json = a.get_leaf_json(doc).unwrap();
    assert!(json.contains(&block));
    assert!(json.contains(&clone));
    assert_eq!(json.matches("original").count(), 2);
}

#[test]
fn duplicate_block_unknown_block_fails() {
    let a = api();
    let doc = a.create_leaf("Doc".to_string()).unwrap();
    let err = a
        .duplicate_block(doc, Uuid::new_v4().to_string())
        .unwrap_err();
    assert!(matches!(err, PinkhaError::NotFound { .. }));
}

// ── Notion picker input validation (no network) ──────────────────────────────

#[test]
fn list_notion_databases_v2025_rejects_oversized_token() {
    let a = api();
    let err = a
        .list_notion_databases_v2025("x".repeat(65 * 1024))
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn list_notion_databases_rejects_oversized_token() {
    let a = api();
    let err = a.list_notion_databases("x".repeat(65 * 1024)).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── get_leaf_meta ───────────────────────────────────────────────────────

#[test]
fn get_leaf_meta_returns_chrome_without_blocks() {
    let a = api();
    let id = a.create_leaf("Meta doc".to_string()).unwrap();
    a.update_leaf_icon(id.clone(), Some("🌸".to_string()))
        .unwrap();
    let meta = a.get_leaf_meta(id.clone()).unwrap();
    assert_eq!(meta.id, id);
    assert_eq!(meta.title_plain, "Meta doc");
    assert_eq!(meta.icon.as_deref(), Some("🌸"));
}

#[test]
fn get_leaf_meta_invalid_uuid_fails() {
    let a = api();
    let err = a.get_leaf_meta("not-a-uuid".to_string()).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn get_leaf_meta_unknown_id_fails() {
    let a = api();
    let err = a.get_leaf_meta(Uuid::new_v4().to_string()).unwrap_err();
    assert!(matches!(err, PinkhaError::NotFound { .. }));
}

// ── super_search ────────────────────────────────────────────────────────────

#[test]
fn super_search_covers_every_axis_and_dedupes_leaves() {
    let a = api();
    // Title hit that ALSO matches in content — must surface once, in titles.
    let both = a.create_leaf("alpha report".to_string()).unwrap();
    a.add_block(
        both.clone(),
        json!({"Text": [{"content": "alpha is here too", "styles": []}]}).to_string(),
    )
    .unwrap();
    // Content-only hit.
    let content_only = a.create_leaf("plain notes".to_string()).unwrap();
    a.add_block(
        content_only.clone(),
        json!({"Text": [{"content": "mentions alpha inside", "styles": []}]}).to_string(),
    )
    .unwrap();
    // Book + shelf hits.
    let _book = a.create_book("alpha base".to_string()).unwrap();
    let _shelf = a.create_shelf("alpha shelf".to_string(), None).unwrap();

    let results = a.super_search("alpha".to_string()).unwrap();
    assert_eq!(results.leaves_by_title.len(), 1);
    assert_eq!(results.leaves_by_title[0].id, both);
    // The title-matching doc is deduplicated out of the content hits.
    assert_eq!(results.leaves_by_content.len(), 1);
    assert_eq!(results.leaves_by_content[0].doc.id, content_only);
    assert!(results.leaves_by_content[0].snippet.contains("alpha"));
    assert_eq!(results.books.len(), 1);
    assert_eq!(results.shelves.len(), 1);
}

#[test]
fn super_search_empty_everywhere_returns_empty_buckets() {
    let a = api();
    let results = a.super_search("nothing".to_string()).unwrap();
    assert!(results.leaves_by_title.is_empty());
    assert!(results.leaves_by_content.is_empty());
    assert!(results.books.is_empty());
    assert!(results.shelves.is_empty());
}

// ── empty_trash ─────────────────────────────────────────────────────────────

#[test]
fn empty_trash_purges_leaves_books_and_shelves() {
    let a = api();
    let d1 = a.create_leaf("Doc 1".to_string()).unwrap();
    let d2 = a.create_leaf("Doc 2".to_string()).unwrap();
    let db = a.create_book("DB".to_string()).unwrap();
    let shelf = a.create_shelf("Shelf".to_string(), None).unwrap();
    a.delete_leaf(d1).unwrap();
    a.delete_leaf(d2).unwrap();
    a.delete_book(db).unwrap();
    a.delete_shelf(shelf.id).unwrap();

    let purged = a.empty_trash().unwrap();
    assert_eq!(purged, 4);
    assert!(a.list_deleted_leaves().unwrap().is_empty());
    assert!(a.list_deleted_books().unwrap().is_empty());
    assert!(a.list_deleted_shelves().unwrap().is_empty());
}

#[test]
fn empty_trash_on_empty_trash_returns_zero() {
    let a = api();
    assert_eq!(a.empty_trash().unwrap(), 0);
}

// ── list_child_shelves ──────────────────────────────────────────────────────

#[test]
fn list_child_shelves_filters_by_parent() {
    let a = api();
    let root = a.create_shelf("Root".to_string(), None).unwrap();
    let child = a
        .create_shelf("Child".to_string(), Some(root.id.clone()))
        .unwrap();

    let top = a.list_child_shelves(None).unwrap();
    assert_eq!(top.len(), 1);
    assert_eq!(top[0].id, root.id);

    let children = a.list_child_shelves(Some(root.id.clone())).unwrap();
    assert_eq!(children.len(), 1);
    assert_eq!(children[0].id, child.id);

    let none = a.list_child_shelves(Some(child.id)).unwrap();
    assert!(none.is_empty());
}

#[test]
fn list_child_shelves_invalid_parent_uuid_fails() {
    let a = api();
    let err = a
        .list_child_shelves(Some("not-a-uuid".to_string()))
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── create_leaf_in_book ─────────────────────────────────────────────

#[test]
fn create_leaf_in_book_fills_title_and_page_link() {
    let a = api();
    let db = a.create_book("Tasks".to_string()).unwrap();
    let (title_id, title_json) = make_title_property("Name");
    a.add_property(db.clone(), title_json).unwrap();
    let page_prop_id = Uuid::new_v4().to_string();
    a.add_property(
        db.clone(),
        json!({"id": page_prop_id, "name": "__pinkha_page__", "type_": "Text"}).to_string(),
    )
    .unwrap();

    let leaf_id = a
        .create_leaf_in_book(db.clone(), "My new row".to_string(), "{}".to_string())
        .unwrap();

    // The leaf exists with the right title.
    let meta = a.get_leaf_meta(leaf_id.clone()).unwrap();
    assert_eq!(meta.title_plain, "My new row");

    // The book gained one entry whose Title and page-link are filled.
    let book_json = a.get_book_json(db).unwrap();
    let book_value: serde_json::Value = serde_json::from_str(&book_json).unwrap();
    let entries = book_value["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 1);
    let values = &entries[0]["values"];
    assert_eq!(values[&page_prop_id]["Text"], leaf_id);
    assert_eq!(values[&title_id]["Title"][0]["content"], "My new row");
    // The entry is linked to the leaf for title propagation.
    assert_eq!(entries[0]["leaf_id"], leaf_id);
}

#[test]
fn create_leaf_in_book_unknown_book_fails_without_creating_leaf() {
    let a = api();
    let before = a.list_leaves().unwrap().len();
    let err = a
        .create_leaf_in_book(
            Uuid::new_v4().to_string(),
            "Orphan".to_string(),
            "{}".to_string(),
        )
        .unwrap_err();
    assert!(matches!(err, PinkhaError::NotFound { .. }));
    assert_eq!(a.list_leaves().unwrap().len(), before);
}

// ── set_published_at_source ──────────────────────────────────────────────────

/// Builds a DB with a Date column + one doc-backed row whose cell holds
/// `date`. Returns (book_id, date_prop_id, entry_id, leaf_id).
fn make_publish_source_fixture(a: &PinkhaApi, date: &str) -> (String, String, String, String) {
    let db = a.create_book("Journal".to_string()).unwrap();
    let prop_id = Uuid::new_v4().to_string();
    a.add_property(
        db.clone(),
        json!({"id": prop_id, "name": "Publication", "type_": "Date"}).to_string(),
    )
    .unwrap();
    let doc = a.create_leaf("Old text".to_string()).unwrap();
    let entry = a
        .attach_leaf_to_book(
            db.clone(),
            doc.clone(),
            json!({ prop_id.clone(): {"Date": date} }).to_string(),
        )
        .unwrap();
    (db, prop_id, entry, doc)
}

fn leaf_published_at(a: &PinkhaApi, leaf_id: &str) -> String {
    a.get_leaf_meta(leaf_id.to_string())
        .unwrap()
        .published_at
}

#[test]
fn adopting_a_date_column_backfills_entries_and_leaves() {
    let a = api();
    let (db, prop, entry, doc) = make_publish_source_fixture(&a, "2023-11-08");

    let touched = a.set_published_at_source(db.clone(), Some(prop)).unwrap();
    assert_eq!(touched, 1);

    let book_json = a.get_book_json(db).unwrap();
    let value: serde_json::Value = serde_json::from_str(&book_json).unwrap();
    let row = value["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["id"] == entry)
        .unwrap()
        .clone();
    assert_eq!(row["published_at"], "2023-11-08");
    assert_eq!(leaf_published_at(&a, &doc), "2023-11-08");
}

#[test]
fn clearing_the_source_resets_rows_to_follow_created_at() {
    let a = api();
    let (db, prop, _entry, doc) = make_publish_source_fixture(&a, "2023-11-08");
    a.set_published_at_source(db.clone(), Some(prop)).unwrap();

    let touched = a.set_published_at_source(db.clone(), None).unwrap();
    assert_eq!(touched, 1);

    // The leaf falls back to its creation date (SQL CASE resolves
    // the empty sentinel against the row's real created_at).
    let meta = a.get_leaf_meta(doc).unwrap();
    assert_eq!(meta.published_at, meta.created_at);
}

#[test]
fn editing_the_source_cell_keeps_publish_date_in_sync() {
    let a = api();
    let (db, prop, entry, doc) = make_publish_source_fixture(&a, "2023-11-08");
    a.set_published_at_source(db.clone(), Some(prop.clone()))
        .unwrap();

    // Live sync: editing the date cell re-dates the row + its leaf.
    a.update_entry(
        db.clone(),
        entry.clone(),
        json!({ prop: {"Date": "2024-01-20"} }).to_string(),
    )
    .unwrap();

    let book_json = a.get_book_json(db.clone()).unwrap();
    assert!(book_json.contains("2024-01-20"));
    assert_eq!(leaf_published_at(&a, &doc), "2024-01-20");
}

#[test]
fn new_rows_inherit_publish_date_from_the_source_cell() {
    let a = api();
    let (db, prop, _entry, _leaf) = make_publish_source_fixture(&a, "2023-11-08");
    a.set_published_at_source(db.clone(), Some(prop.clone()))
        .unwrap();

    let entry2 = a
        .add_entry(
            db.clone(),
            json!({ prop: {"Date": "2022-05-01"} }).to_string(),
        )
        .unwrap();
    let book_json = a.get_book_json(db).unwrap();
    let value: serde_json::Value = serde_json::from_str(&book_json).unwrap();
    let row = value["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["id"] == entry2)
        .unwrap()
        .clone();
    assert_eq!(row["published_at"], "2022-05-01");
}

#[test]
fn adopting_a_non_date_property_fails() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let prop_id = Uuid::new_v4().to_string();
    a.add_property(db.clone(), make_text_property("Notes"))
        .unwrap();
    let err = a.set_published_at_source(db, Some(prop_id)).unwrap_err();
    // Unknown UUID (the Text prop has its own id) → NotFound; a known
    // non-Date prop would be InvalidOperation. Both reject the adopt.
    assert!(matches!(
        err,
        PinkhaError::NotFound { .. } | PinkhaError::InvalidOperation { .. }
    ));
}

#[test]
fn adopting_known_text_property_is_invalid_operation() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let prop_id = Uuid::new_v4().to_string();
    a.add_property(
        db.clone(),
        json!({"id": prop_id, "name": "Notes", "type_": "Text"}).to_string(),
    )
    .unwrap();
    let err = a.set_published_at_source(db, Some(prop_id)).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── delete_book_cascade / restore_book_cascade ──────────────────────

#[test]
fn delete_cascade_trashes_book_and_backing_leaves() {
    let a = api();
    let db = a.create_book("Book".to_string()).unwrap();
    let d1 = a.create_leaf("Page 1".to_string()).unwrap();
    let d2 = a.create_leaf("Page 2".to_string()).unwrap();
    a.attach_leaf_to_book(db.clone(), d1.clone(), "{}".to_string())
        .unwrap();
    a.attach_leaf_to_book(db.clone(), d2.clone(), "{}".to_string())
        .unwrap();
    // A standalone row with no backing leaf must not break the cascade.
    a.add_entry(db.clone(), "{}".to_string()).unwrap();

    let deleted = a.delete_book_cascade(db.clone()).unwrap();
    assert_eq!(deleted, 2);
    assert!(a.list_books().unwrap().is_empty());
    assert!(a.list_leaves().unwrap().is_empty());
    // Everything is recoverable from the trash.
    assert_eq!(a.list_deleted_leaves().unwrap().len(), 2);
    assert_eq!(a.list_deleted_books().unwrap().len(), 1);
}

#[test]
fn delete_cascade_skips_leaves_already_in_the_trash() {
    let a = api();
    let db = a.create_book("Book".to_string()).unwrap();
    let d1 = a.create_leaf("Page 1".to_string()).unwrap();
    a.attach_leaf_to_book(db.clone(), d1.clone(), "{}".to_string())
        .unwrap();
    a.delete_leaf(d1).unwrap();

    let deleted = a.delete_book_cascade(db).unwrap();
    assert_eq!(deleted, 0);
}

#[test]
fn restore_cascade_brings_back_book_and_leaves() {
    let a = api();
    let db = a.create_book("Book".to_string()).unwrap();
    let d1 = a.create_leaf("Page 1".to_string()).unwrap();
    a.attach_leaf_to_book(db.clone(), d1.clone(), "{}".to_string())
        .unwrap();
    a.delete_book_cascade(db.clone()).unwrap();

    let restored = a.restore_book_cascade(db).unwrap();
    assert_eq!(restored, 1);
    assert_eq!(a.list_books().unwrap().len(), 1);
    assert_eq!(a.list_leaves().unwrap().len(), 1);
    assert!(a.list_deleted_leaves().unwrap().is_empty());
}

#[test]
fn restore_cascade_skips_leaves_that_stayed_active() {
    let a = api();
    let db = a.create_book("Book".to_string()).unwrap();
    let d1 = a.create_leaf("Page 1".to_string()).unwrap();
    a.attach_leaf_to_book(db.clone(), d1, "{}".to_string())
        .unwrap();
    // DB-only delete: the doc stays active.
    a.delete_book(db.clone()).unwrap();

    let restored = a.restore_book_cascade(db).unwrap();
    assert_eq!(restored, 0);
    assert_eq!(a.list_leaves().unwrap().len(), 1);
}

#[test]
fn delete_cascade_unknown_book_fails() {
    let a = api();
    let err = a
        .delete_book_cascade(Uuid::new_v4().to_string())
        .unwrap_err();
    assert!(matches!(err, PinkhaError::NotFound { .. }));
}

// ── Locked book guards ───────────────────────────────────────────────────

#[test]
fn locked_book_rejects_title_and_description_edits() {
    let a = api();
    let db = a.create_book("Sealed".to_string()).unwrap();
    a.update_book_locked(db.clone(), true).unwrap();

    let err = a
        .update_book_title(db.clone(), "New title".to_string())
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
    let err = a
        .update_book_description(db.clone(), "New description".to_string())
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));

    // Unlocking lifts the wall.
    a.update_book_locked(db.clone(), false).unwrap();
    a.update_book_title(db.clone(), "New title".to_string())
        .unwrap();
    assert!(a.get_book_json(db).unwrap().contains("New title"));
}

// ── Date grouping FFI ───────────────────────────────────────────────────────

fn make_date_grouping_json(source: &str, granularity: &str, ascending: bool) -> String {
    let source_value = match source {
        "Created" | "Published" => json!(source),
        prop_id => json!({"Property": prop_id}),
    };
    json!({
        "source": source_value,
        "granularity": granularity,
        "ascending": ascending,
    })
    .to_string()
}

#[test]
fn date_grouped_query_returns_empty_array_when_no_grouping() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let (_, view_json) = make_view("V");
    let view = a.add_view(db.clone(), view_json).unwrap();
    let json = a
        .date_grouped_query_book_json(db, view, String::new())
        .unwrap();
    assert_eq!(json, "[]");
}

#[test]
fn date_grouped_query_with_override_returns_tree() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let (_, view_json) = make_view("V");
    let view = a.add_view(db.clone(), view_json).unwrap();
    a.add_entry(db.clone(), "{}".to_string()).unwrap();

    let override_json = make_date_grouping_json("Created", "Year", false);
    let json = a
        .date_grouped_query_book_json(db, view, override_json)
        .unwrap();
    assert!(json.starts_with('['));
    assert!(json.contains("label_year"));
}

#[test]
fn date_grouped_query_with_malformed_override_fails() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let (_, view_json) = make_view("V");
    let view = a.add_view(db.clone(), view_json).unwrap();
    let err = a
        .date_grouped_query_book_json(db, view, "{not json".to_string())
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn date_grouped_query_with_invalid_uuid_fails() {
    let a = api();
    let err = a
        .date_grouped_query_book_json(
            "not-uuid".to_string(),
            Uuid::new_v4().to_string(),
            String::new(),
        )
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn set_view_date_grouping_persists_then_clears() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let (_, view_json) = make_view("V");
    let view = a.add_view(db.clone(), view_json).unwrap();

    // Setting a config makes date_grouped_query return a non-empty tree
    // for any entry that exists.
    a.add_entry(db.clone(), "{}".to_string()).unwrap();
    let grouping = make_date_grouping_json("Created", "Year", false);
    a.set_view_date_grouping(db.clone(), view.clone(), grouping)
        .unwrap();
    let json = a
        .date_grouped_query_book_json(db.clone(), view.clone(), String::new())
        .unwrap();
    assert!(json.contains("label_year"));

    // Clearing it returns empty.
    a.set_view_date_grouping(db.clone(), view.clone(), String::new())
        .unwrap();
    let cleared = a
        .date_grouped_query_book_json(db, view, String::new())
        .unwrap();
    assert_eq!(cleared, "[]");
}

#[test]
fn set_view_date_grouping_with_malformed_json_fails() {
    let a = api();
    let db = a.create_book("DB".to_string()).unwrap();
    let (_, view_json) = make_view("V");
    let view = a.add_view(db.clone(), view_json).unwrap();
    let err = a
        .set_view_date_grouping(db, view, "{bad".to_string())
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn set_view_date_grouping_with_invalid_uuid_fails() {
    let a = api();
    let err = a
        .set_view_date_grouping(
            "nope".to_string(),
            Uuid::new_v4().to_string(),
            String::new(),
        )
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── Root visibility when a shelf is discarded ───────────────────────────────
//
// `ShelfRepository::delete` is deliberately non-destructive: it soft-deletes
// the shelf and leaves every `leaf.shelf_id` pointing at it, so restoring the
// shelf brings the whole subtree back. That makes "is this leaf at the root?"
// a question about the *shelf's* state, not just about `shelf_id` being null.

#[test]
fn discarding_a_shelf_returns_its_leaves_to_the_library_root() {
    let api = api();
    let shelf = api.create_shelf("Work".into(), None).expect("shelf");
    let leaf = api.create_leaf("Filed away".into()).expect("leaf");
    api.move_leaf_to_shelf(leaf.clone(), Some(shelf.id.clone()))
        .expect("file");

    // Filed: gone from the root listing, which is the whole point of shelves.
    let roots = api.list_root_leaves().expect("roots");
    assert!(!roots.iter().any(|m| m.id == leaf), "filed leaf still at root");

    api.delete_shelf(shelf.id.clone()).expect("discard shelf");

    // The shelf is in Compost, but the leaf was never discarded. It must
    // reappear at the root — otherwise it belongs to a container the user
    // cannot open and is invisible everywhere, which reads as data loss.
    let roots = api.list_root_leaves().expect("roots after discard");
    assert!(
        roots.iter().any(|m| m.id == leaf),
        "leaf vanished from the library when its shelf was discarded"
    );
}

#[test]
fn restoring_a_shelf_takes_its_leaves_back_out_of_the_root() {
    let api = api();
    let shelf = api.create_shelf("Work".into(), None).expect("shelf");
    let leaf = api.create_leaf("Filed away".into()).expect("leaf");
    api.move_leaf_to_shelf(leaf.clone(), Some(shelf.id.clone()))
        .expect("file");
    api.delete_shelf(shelf.id.clone()).expect("discard");
    api.restore_shelf(shelf.id.clone()).expect("restore");

    let roots = api.list_root_leaves().expect("roots");
    assert!(
        !roots.iter().any(|m| m.id == leaf),
        "restored shelf did not reclaim its leaf"
    );
    let in_shelf = api.list_leaves_in_shelf(Some(shelf.id)).expect("in shelf");
    assert!(in_shelf.iter().any(|m| m.id == leaf));
}

#[test]
fn the_two_root_listings_agree() {
    // `list_root_leaves` and `list_leaves_in_shelf(None)` are two spellings
    // of the same question and drifted apart once: one filtered on
    // `shelf_id.is_none()` in Rust while the other used the SQL predicate
    // that treats a trashed shelf as no shelf.
    let api = api();
    let shelf = api.create_shelf("S".into(), None).expect("shelf");
    let filed = api.create_leaf("Filed".into()).expect("leaf");
    let loose = api.create_leaf("Loose".into()).expect("leaf");
    api.move_leaf_to_shelf(filed.clone(), Some(shelf.id.clone()))
        .expect("file");
    api.delete_shelf(shelf.id).expect("discard");

    let mut a: Vec<String> = api
        .list_root_leaves()
        .expect("roots")
        .into_iter()
        .map(|m| m.id)
        .collect();
    let mut b: Vec<String> = api
        .list_leaves_in_shelf(None)
        .expect("shelfless")
        .into_iter()
        .map(|m| m.id)
        .collect();
    a.sort();
    b.sort();
    assert_eq!(a, b);
    assert!(a.contains(&filed) && a.contains(&loose));
}
