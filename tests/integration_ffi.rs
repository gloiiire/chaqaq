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
        api.create_document("Persisted".to_string()).expect("create")
    };
    let api2 = PinkhaApi::new(path.clone()).expect("reopen");
    let json = api2.get_document_json(id).expect("get");
    assert!(json.contains("Persisted"));
    let _ = std::fs::remove_file(&path);
}

#[test]
fn new_on_invalid_path_fails() {
    let result = PinkhaApi::new("/nonexistent_dir_xyz/pinkha.db".to_string());
    assert!(result.is_err());
}

// ── Documents ───────────────────────────────────────────────────────────────

#[test]
fn create_and_get_document_roundtrip() {
    let a = api();
    let id = a.create_document("Hello".to_string()).expect("create");
    let json = a.get_document_json(id.clone()).expect("get");
    assert!(json.contains("Hello"));
    assert!(json.contains(&id));
}

#[test]
fn list_documents_returns_created_docs() {
    let a = api();
    a.create_document("A".to_string()).expect("a");
    a.create_document("B".to_string()).expect("b");
    let list = a.list_documents().expect("list");
    assert_eq!(list.len(), 2);
}

#[test]
fn delete_document_removes_from_list() {
    let a = api();
    let id = a.create_document("Trash".to_string()).expect("create");
    a.delete_document(id.clone()).expect("delete");
    assert!(matches!(
        a.get_document_json(id).unwrap_err(),
        PinkhaError::NotFound { .. }
    ));
}

#[test]
fn delete_document_invalid_uuid_fails() {
    let a = api();
    let err = a.delete_document("not-a-uuid".to_string()).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn delete_all_documents_returns_count() {
    let a = api();
    a.create_document("a".to_string()).unwrap();
    a.create_document("b".to_string()).unwrap();
    a.create_document("c".to_string()).unwrap();
    let n = a.delete_all_documents().expect("delete all");
    assert_eq!(n, 3);
    assert_eq!(a.list_documents().unwrap().len(), 0);
}

#[test]
fn delete_all_documents_on_empty_is_zero() {
    let a = api();
    assert_eq!(a.delete_all_documents().unwrap(), 0);
}

#[test]
fn update_document_title() {
    let a = api();
    let id = a.create_document("Old".to_string()).unwrap();
    a.update_document_title(id.clone(), "New".to_string())
        .expect("rename");
    let json = a.get_document_json(id).unwrap();
    assert!(json.contains("New"));
}

#[test]
fn update_document_title_too_large_fails() {
    let a = api();
    let id = a.create_document("X".to_string()).unwrap();
    let huge = "a".repeat(70 * 1024);
    let err = a.update_document_title(id, huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn update_document_cover_set_and_clear() {
    let a = api();
    let id = a.create_document("X".to_string()).unwrap();
    a.update_document_cover(id.clone(), Some("🌸".to_string()))
        .expect("set cover");
    let json = a.get_document_json(id.clone()).unwrap();
    assert!(json.contains("🌸"));
    a.update_document_cover(id.clone(), None).expect("clear cover");
}

#[test]
fn create_document_title_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.create_document(huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn get_document_invalid_uuid_fails() {
    let a = api();
    let err = a.get_document_json("zzz".to_string()).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn get_document_not_found_fails() {
    let a = api();
    let err = a
        .get_document_json(Uuid::new_v4().to_string())
        .unwrap_err();
    assert!(matches!(err, PinkhaError::NotFound { .. }));
}

// ── Blocks ──────────────────────────────────────────────────────────────────

fn text_block_json(text: &str) -> String {
    json!({"Text": [{"content": text, "styles": []}]}).to_string()
}

#[test]
fn add_block_returns_uuid() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
    let block_id = a.add_block(doc, text_block_json("Hello")).expect("add block");
    assert!(Uuid::parse_str(&block_id).is_ok());
}

#[test]
fn add_block_with_malformed_json_fails() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
    let err = a.add_block(doc, "not json".to_string()).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn add_block_oversized_json_fails() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
    let huge = "a".repeat(6 * 1024 * 1024);
    let err = a.add_block(doc, huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn update_block_replaces_content() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
    let block = a.add_block(doc.clone(), text_block_json("Old")).unwrap();
    a.update_block(doc.clone(), block.clone(), text_block_json("New"))
        .expect("update");
    let json = a.get_document_json(doc).unwrap();
    assert!(json.contains("New"));
}

#[test]
fn set_block_color_sets_and_clears() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
    let block = a.add_block(doc.clone(), text_block_json("c")).unwrap();
    a.set_block_color(doc.clone(), block.clone(), Some("red".to_string()))
        .expect("set color");
    a.set_block_color(doc, block, None).expect("clear color");
}

#[test]
fn set_block_color_too_large_fails() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
    let block = a.add_block(doc.clone(), text_block_json("c")).unwrap();
    let huge = "r".repeat(70 * 1024);
    let err = a.set_block_color(doc, block, Some(huge)).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn delete_block_removes_it() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
    let block = a.add_block(doc.clone(), text_block_json("x")).unwrap();
    a.delete_block(doc, block).expect("delete");
}

#[test]
fn reorder_blocks() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
    let b1 = a.add_block(doc.clone(), text_block_json("1")).unwrap();
    let b2 = a.add_block(doc.clone(), text_block_json("2")).unwrap();
    a.reorder_blocks(doc, vec![b2, b1]).expect("reorder");
}

#[test]
fn reorder_blocks_invalid_uuid_fails() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
    let err = a
        .reorder_blocks(doc, vec!["not-a-uuid".to_string()])
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn add_child_block() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
    let parent = a.add_block(doc.clone(), text_block_json("p")).unwrap();
    let child = a
        .add_child_block(doc, parent, text_block_json("c"))
        .expect("add child");
    assert!(Uuid::parse_str(&child).is_ok());
}

#[test]
fn reorder_child_blocks() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
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
    let doc = a.create_document("Doc".to_string()).unwrap();
    let parent = a.add_block(doc.clone(), text_block_json("p")).unwrap();
    let block = a.add_block(doc.clone(), text_block_json("b")).unwrap();
    a.move_block(doc.clone(), block.clone(), Some(parent.clone()))
        .expect("move to parent");
    a.move_block(doc, block, None).expect("move to root");
}

#[test]
fn move_block_invalid_parent_uuid_fails() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
    let block = a.add_block(doc.clone(), text_block_json("b")).unwrap();
    let err = a
        .move_block(doc, block, Some("not-a-uuid".to_string()))
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn indent_and_outdent_block() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
    let b1 = a.add_block(doc.clone(), text_block_json("1")).unwrap();
    let b2 = a.add_block(doc.clone(), text_block_json("2")).unwrap();
    a.indent_block(doc.clone(), b2.clone()).expect("indent");
    a.outdent_block(doc, b2).expect("outdent");
    let _ = b1;
}

#[test]
fn indent_first_block_fails() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
    let b1 = a.add_block(doc.clone(), text_block_json("only")).unwrap();
    let err = a.indent_block(doc, b1).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn outdent_root_block_fails() {
    let a = api();
    let doc = a.create_document("Doc".to_string()).unwrap();
    let b = a.add_block(doc.clone(), text_block_json("x")).unwrap();
    let err = a.outdent_block(doc, b).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── Search ──────────────────────────────────────────────────────────────────

#[test]
fn search_documents_by_title() {
    let a = api();
    a.create_document("Apple pie".to_string()).unwrap();
    a.create_document("Banana bread".to_string()).unwrap();
    a.create_document("Apple cake".to_string()).unwrap();
    let hits = a.search_documents("apple".to_string()).unwrap();
    assert_eq!(hits.len(), 2);
}

#[test]
fn search_documents_query_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.search_documents(huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn search_in_blocks() {
    let a = api();
    let doc = a.create_document("Note".to_string()).unwrap();
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

// ── Databases ───────────────────────────────────────────────────────────────

#[test]
fn create_and_list_databases() {
    let a = api();
    a.create_database("Tasks".to_string()).unwrap();
    a.create_database("People".to_string()).unwrap();
    assert_eq!(a.list_databases().unwrap().len(), 2);
}

#[test]
fn create_database_title_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.create_database(huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn get_database_returns_json() {
    let a = api();
    let id = a.create_database("Tasks".to_string()).unwrap();
    let json = a.get_database_json(id.clone()).unwrap();
    assert!(json.contains(&id));
}

#[test]
fn get_database_not_found() {
    let a = api();
    let err = a.get_database_json(Uuid::new_v4().to_string()).unwrap_err();
    assert!(matches!(err, PinkhaError::NotFound { .. }));
}

#[test]
fn delete_database() {
    let a = api();
    let id = a.create_database("Doomed".to_string()).unwrap();
    a.delete_database(id.clone()).unwrap();
    assert!(matches!(
        a.get_database_json(id).unwrap_err(),
        PinkhaError::NotFound { .. }
    ));
}

#[test]
fn delete_all_databases_returns_count() {
    let a = api();
    a.create_database("a".to_string()).unwrap();
    a.create_database("b".to_string()).unwrap();
    assert_eq!(a.delete_all_databases().unwrap(), 2);
    assert_eq!(a.list_databases().unwrap().len(), 0);
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
fn add_property_to_database() {
    let a = api();
    let db = a.create_database("DB".to_string()).unwrap();
    a.add_property(db.clone(), make_text_property("Notes")).unwrap();
    let json = a.get_database_json(db).unwrap();
    assert!(json.contains("Notes"));
}

#[test]
fn add_property_invalid_db_uuid_fails() {
    let a = api();
    let err = a
        .add_property("not-uuid".to_string(), make_text_property("X"))
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn rename_property_changes_name() {
    let a = api();
    let db = a.create_database("DB".to_string()).unwrap();
    let prop_id = Uuid::new_v4().to_string();
    let prop_json = json!({"id": prop_id, "name": "Old", "type_": "Text"}).to_string();
    a.add_property(db.clone(), prop_json).unwrap();
    a.rename_property(db.clone(), prop_id, "New".to_string())
        .unwrap();
    let json = a.get_database_json(db).unwrap();
    assert!(json.contains("New"));
}

#[test]
fn rename_property_too_large_fails() {
    let a = api();
    let db = a.create_database("DB".to_string()).unwrap();
    let prop_id = Uuid::new_v4().to_string();
    let huge = "a".repeat(70 * 1024);
    let err = a.rename_property(db, prop_id, huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn delete_property_clears_values() {
    let a = api();
    let db = a.create_database("DB".to_string()).unwrap();
    let prop_id = Uuid::new_v4().to_string();
    let prop_json = json!({"id": prop_id, "name": "C", "type_": "Text"}).to_string();
    a.add_property(db.clone(), prop_json).unwrap();
    a.delete_property(db, prop_id).unwrap();
}

#[test]
fn add_entry_to_database() {
    let a = api();
    let db = a.create_database("DB".to_string()).unwrap();
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
    let db = a.create_database("DB".to_string()).unwrap();
    let err = a.add_entry(db, "broken".to_string()).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn update_entry_propagates_title_when_linked() {
    let a = api();
    let db = a.create_database("Tasks".to_string()).unwrap();
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
    let db = a.create_database("DB".to_string()).unwrap();
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
    let db = a.create_database("DB".to_string()).unwrap();
    let (_, view_json) = make_view("Default");
    let view = a.add_view(db.clone(), view_json).unwrap();
    let entries_json = a.query_database_json(db, view).unwrap();
    assert_eq!(entries_json, "[]");
}

#[test]
fn update_view_filters_and_sorts() {
    let a = api();
    let db = a.create_database("DB".to_string()).unwrap();
    let (_, view_json) = make_view("V");
    let view = a.add_view(db.clone(), view_json).unwrap();
    a.update_view(db, view, "[]".to_string(), "[]".to_string()).unwrap();
}

#[test]
fn set_view_sort_with_and_without_property() {
    let a = api();
    let db = a.create_database("DB".to_string()).unwrap();
    let (_, view_json) = make_view("V");
    let view = a.add_view(db.clone(), view_json).unwrap();
    let prop = Uuid::new_v4().to_string();
    a.set_view_sort(db.clone(), view.clone(), Some(prop), true).unwrap();
    a.set_view_sort(db, view, None, false).unwrap();
}

#[test]
fn set_view_sort_invalid_property_uuid_fails() {
    let a = api();
    let db = a.create_database("DB".to_string()).unwrap();
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
    let db = a.create_database("DB".to_string()).unwrap();
    let (_, v1) = make_view("V1");
    let view1 = a.add_view(db.clone(), v1).unwrap();
    let (_, v2) = make_view("V2");
    let _ = a.add_view(db.clone(), v2).unwrap();
    a.delete_view(db, view1).unwrap();
}

#[test]
fn query_database_with_rollups() {
    let a = api();
    let db = a.create_database("DB".to_string()).unwrap();
    let (_, view_json) = make_view("V");
    let view = a.add_view(db.clone(), view_json).unwrap();
    let entries_json = a.query_database_with_rollups_json(db, view).unwrap();
    assert_eq!(entries_json, "[]");
}

#[test]
fn grouped_query_database() {
    let a = api();
    let db = a.create_database("DB".to_string()).unwrap();
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
        .grouped_query_database_json(db, view, prop_id.to_string())
        .unwrap();
    assert!(groups.starts_with('['));
}

#[test]
fn column_aggregate_count() {
    let a = api();
    let db = a.create_database("DB".to_string()).unwrap();
    let prop_id = Uuid::new_v4().to_string();
    let prop_json = json!({"id": prop_id, "name": "N", "type_": "Number"}).to_string();
    a.add_property(db.clone(), prop_json.clone()).unwrap();
    let result = a
        .column_aggregate_database_json(db, prop_id, json!("Count").to_string())
        .unwrap();
    assert!(result.contains("Number"));
}

#[test]
fn column_aggregate_invalid_json_fails() {
    let a = api();
    let db = a.create_database("DB".to_string()).unwrap();
    let err = a
        .column_aggregate_database_json(
            db,
            Uuid::new_v4().to_string(),
            "garbage".to_string(),
        )
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn search_database_entries() {
    let a = api();
    let db = a.create_database("DB".to_string()).unwrap();
    let prop_id = Uuid::new_v4().to_string();
    let prop_json = json!({"id": prop_id, "name": "Note", "type_": "Text"}).to_string();
    a.add_property(db.clone(), prop_json).unwrap();
    let values = json!({prop_id: {"Text": "needle"}}).to_string();
    a.add_entry(db.clone(), values).unwrap();
    let json = a.search_database_entries_json(db, "needle".to_string()).unwrap();
    assert!(json.contains("needle"));
}

#[test]
fn search_database_entries_query_too_large_fails() {
    let a = api();
    let db = a.create_database("DB".to_string()).unwrap();
    let huge = "a".repeat(70 * 1024);
    let err = a.search_database_entries_json(db, huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── Folders ─────────────────────────────────────────────────────────────────

#[test]
fn create_and_get_folder() {
    let a = api();
    let f = a.create_folder("Inbox".to_string(), None).unwrap();
    assert_eq!(f.name, "Inbox");
    assert!(f.parent_id.is_none());
    let loaded = a.get_folder(f.id.clone()).unwrap();
    assert_eq!(loaded.name, "Inbox");
}

#[test]
fn create_nested_folder() {
    let a = api();
    let parent = a.create_folder("Parent".to_string(), None).unwrap();
    let child = a
        .create_folder("Child".to_string(), Some(parent.id.clone()))
        .unwrap();
    assert_eq!(child.parent_id.as_deref(), Some(parent.id.as_str()));
}

#[test]
fn create_folder_name_too_large_fails() {
    let a = api();
    let huge = "a".repeat(70 * 1024);
    let err = a.create_folder(huge, None).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn create_folder_with_invalid_parent_uuid_fails() {
    let a = api();
    let err = a
        .create_folder("X".to_string(), Some("not-uuid".to_string()))
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn list_folders_returns_all() {
    let a = api();
    a.create_folder("Alpha".to_string(), None).unwrap();
    a.create_folder("Beta".to_string(), None).unwrap();
    assert_eq!(a.list_folders().unwrap().len(), 2);
}

#[test]
fn rename_folder_changes_name() {
    let a = api();
    let f = a.create_folder("Old".to_string(), None).unwrap();
    a.rename_folder(f.id.clone(), "New".to_string()).unwrap();
    assert_eq!(a.get_folder(f.id).unwrap().name, "New");
}

#[test]
fn rename_folder_name_too_large_fails() {
    let a = api();
    let f = a.create_folder("X".to_string(), None).unwrap();
    let huge = "a".repeat(70 * 1024);
    let err = a.rename_folder(f.id, huge).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn delete_folder() {
    let a = api();
    let f = a.create_folder("X".to_string(), None).unwrap();
    a.delete_folder(f.id.clone()).unwrap();
    let err = a.get_folder(f.id).unwrap_err();
    assert!(matches!(err, PinkhaError::NotFound { .. }));
}

#[test]
fn move_folder_to_new_parent() {
    let a = api();
    let a_folder = a.create_folder("A".to_string(), None).unwrap();
    let b = a.create_folder("B".to_string(), None).unwrap();
    a.move_folder_to(a_folder.id.clone(), Some(b.id.clone())).unwrap();
    assert_eq!(
        a.get_folder(a_folder.id).unwrap().parent_id.as_deref(),
        Some(b.id.as_str())
    );
}

#[test]
fn move_folder_to_root() {
    let a = api();
    let parent = a.create_folder("P".to_string(), None).unwrap();
    let child = a
        .create_folder("C".to_string(), Some(parent.id.clone()))
        .unwrap();
    a.move_folder_to(child.id.clone(), None).unwrap();
    assert!(a.get_folder(child.id).unwrap().parent_id.is_none());
}

#[test]
fn move_folder_with_invalid_uuid_fails() {
    let a = api();
    let err = a
        .move_folder_to("nope".to_string(), None)
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn move_document_to_folder_and_list() {
    let a = api();
    let f = a.create_folder("Box".to_string(), None).unwrap();
    let doc = a.create_document("Note".to_string()).unwrap();
    a.move_document_to_folder(doc.clone(), Some(f.id.clone()))
        .unwrap();
    let in_folder = a.list_documents_in_folder(Some(f.id)).unwrap();
    assert_eq!(in_folder.len(), 1);
    let at_root = a.list_documents_in_folder(None).unwrap();
    assert_eq!(at_root.len(), 0);
    a.move_document_to_folder(doc, None).unwrap();
    let at_root = a.list_documents_in_folder(None).unwrap();
    assert_eq!(at_root.len(), 1);
}

#[test]
fn list_documents_in_folder_with_invalid_uuid_fails() {
    let a = api();
    let err = a
        .list_documents_in_folder(Some("garbage".to_string()))
        .unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

// ── Imports — validation paths only ────────────────────────────────────────

#[test]
fn import_from_notion_with_empty_token_or_db_id_does_not_panic() {
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
    let err = a.import_from_notion(huge, "db".to_string(), None).unwrap_err();
    assert!(matches!(err, PinkhaError::InvalidOperation { .. }));
}

#[test]
fn import_from_notion_db_id_too_large_fails() {
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
async fn import_from_craft_textbundle_with_empty_dir_succeeds_with_zero_docs() {
    let a = api();
    // Existing, empty directory → no error, just 0 imports.
    let dir = std::env::temp_dir().join(format!("pinkha-test-empty-{}", Uuid::new_v4()));
    std::fs::create_dir(&dir).expect("mkdir");
    let result = a
        .import_from_craft_textbundle(dir.to_string_lossy().to_string())
        .await
        .expect("empty dir should succeed");
    assert_eq!(result.documents, 0);
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
fn error_display_renders_french_messages() {
    assert!(format!(
        "{}",
        PinkhaError::NotFound { id: "abc".into() }
    )
    .contains("non trouvé"));
    assert!(format!(
        "{}",
        PinkhaError::InvalidOperation { detail: "x".into() }
    )
    .contains("invalide"));
    assert!(format!(
        "{}",
        PinkhaError::Storage { detail: "x".into() }
    )
    .contains("stockage"));
}

#[test]
fn error_debug_does_not_panic() {
    let e = PinkhaError::NotFound { id: "abc".into() };
    let _ = format!("{:?}", e);
}

// ── Folder metadata round-trip ─────────────────────────────────────────────

#[test]
fn folder_metadata_includes_timestamps() {
    let a = api();
    let f = a.create_folder("X".to_string(), None).unwrap();
    assert!(!f.created_at.is_empty());
    assert!(!f.updated_at.is_empty());
}

#[test]
fn doc_metadata_includes_timestamps_and_folder() {
    let a = api();
    let folder = a.create_folder("F".to_string(), None).unwrap();
    let doc_id = a.create_document("D".to_string()).unwrap();
    a.move_document_to_folder(doc_id.clone(), Some(folder.id.clone())).unwrap();
    let in_folder = a.list_documents_in_folder(Some(folder.id.clone())).unwrap();
    assert_eq!(in_folder.len(), 1);
    let meta = &in_folder[0];
    assert!(!meta.updated_at.is_empty());
    assert!(!meta.created_at.is_empty());
    assert_eq!(meta.folder_id.as_deref(), Some(folder.id.as_str()));
}

#[test]
fn db_metadata_includes_timestamps() {
    let a = api();
    a.create_database("X".to_string()).unwrap();
    let list = a.list_databases().unwrap();
    assert_eq!(list.len(), 1);
    let meta = &list[0];
    assert!(!meta.updated_at.is_empty());
    assert!(!meta.created_at.is_empty());
}
