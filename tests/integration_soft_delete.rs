//! Tests d'intégration pour la corbeille (soft delete + restore + purge).
//!
//! Exerce les FFI `list_deleted_*`, `restore_*`, `purge_*` pour les 4 types :
//! leaves, books, shelves, entries.

use pinkha::ffi::PinkhaApi;

fn api() -> PinkhaApi {
    PinkhaApi::new(":memory:".into()).unwrap()
}

// ── Leaves ────────────────────────────────────────────────────────────────

#[test]
fn leaf_soft_delete_restore_purge_roundtrip() {
    let api = api();
    let id = api.create_leaf("À supprimer".into()).unwrap();

    // delete (soft) → disparaît de list_leaves, apparaît dans list_deleted_leaves
    api.delete_leaf(id.clone()).unwrap();
    assert_eq!(api.list_leaves().unwrap().len(), 0);
    let deleted = api.list_deleted_leaves().unwrap();
    assert_eq!(deleted.len(), 1);
    assert_eq!(deleted[0].id, id);

    // restore → revient dans la liste active, disparaît de la corbeille
    api.restore_leaf(id.clone()).unwrap();
    assert_eq!(api.list_leaves().unwrap().len(), 1);
    assert_eq!(api.list_deleted_leaves().unwrap().len(), 0);

    // re-delete puis purge → hard delete : ni dans active, ni dans corbeille
    api.delete_leaf(id.clone()).unwrap();
    api.purge_leaf(id.clone()).unwrap();
    assert_eq!(api.list_leaves().unwrap().len(), 0);
    assert_eq!(api.list_deleted_leaves().unwrap().len(), 0);
}

#[test]
fn leaf_purge_refuses_live_leaf() {
    let api = api();
    let id = api.create_leaf("Encore vivant".into()).unwrap();
    // purge un doc qui n'est pas en corbeille → InvalidOperation
    assert!(api.purge_leaf(id).is_err());
}

#[test]
fn leaf_restore_unknown_id_fails() {
    let api = api();
    let bogus = uuid::Uuid::new_v4().to_string();
    assert!(api.restore_leaf(bogus).is_err());
}

// ── Books ────────────────────────────────────────────────────────────────

#[test]
fn book_soft_delete_restore_purge_roundtrip() {
    let api = api();
    let id = api.create_book("Tasks".into()).unwrap();

    api.delete_book(id.clone()).unwrap();
    assert_eq!(api.list_books().unwrap().len(), 0);
    assert_eq!(api.list_deleted_books().unwrap().len(), 1);

    api.restore_book(id.clone()).unwrap();
    assert_eq!(api.list_books().unwrap().len(), 1);
    assert_eq!(api.list_deleted_books().unwrap().len(), 0);

    api.delete_book(id.clone()).unwrap();
    api.purge_book(id).unwrap();
    assert_eq!(api.list_deleted_books().unwrap().len(), 0);
}

#[test]
fn book_purge_refuses_live() {
    let api = api();
    let id = api.create_book("Live".into()).unwrap();
    assert!(api.purge_book(id).is_err());
}

// ── Shelves ──────────────────────────────────────────────────────────────────

#[test]
fn shelf_soft_delete_restore_purge_roundtrip() {
    let api = api();
    let shelf = api.create_shelf("Box".into(), None).unwrap();

    api.delete_shelf(shelf.id.clone()).unwrap();
    assert_eq!(api.list_shelves().unwrap().len(), 0);
    assert_eq!(api.list_deleted_shelves().unwrap().len(), 1);

    api.restore_shelf(shelf.id.clone()).unwrap();
    assert_eq!(api.list_shelves().unwrap().len(), 1);

    api.delete_shelf(shelf.id.clone()).unwrap();
    api.purge_shelf(shelf.id).unwrap();
    assert_eq!(api.list_deleted_shelves().unwrap().len(), 0);
}

#[test]
fn shelf_purge_refuses_live() {
    let api = api();
    let shelf = api.create_shelf("Live".into(), None).unwrap();
    assert!(api.purge_shelf(shelf.id).is_err());
}

// ── Entries ──────────────────────────────────────────────────────────────────

#[test]
fn entry_soft_delete_restore_purge_roundtrip() {
    let api = api();
    let book_id = api.create_book("DB".into()).unwrap();
    let entry_id = api
        .add_entry(book_id.clone(), "{}".into())
        .expect("add_entry should succeed with empty values");

    // delete entry (soft) → disparaît du query mais reste dans le JSON
    api.delete_entry(book_id.clone(), entry_id.clone()).unwrap();
    let deleted_list_json = api
        .list_deleted_entries_json(book_id.clone())
        .expect("list_deleted_entries_json");
    assert!(deleted_list_json.contains(&entry_id));

    // restore → réapparaît
    api.restore_entry(book_id.clone(), entry_id.clone())
        .unwrap();
    let after_restore = api
        .list_deleted_entries_json(book_id.clone())
        .expect("list_deleted_entries_json");
    assert_eq!(after_restore, "[]");

    // re-delete + purge → hard delete
    api.delete_entry(book_id.clone(), entry_id.clone()).unwrap();
    api.purge_entry(book_id.clone(), entry_id.clone()).unwrap();
    let final_list = api
        .list_deleted_entries_json(book_id)
        .expect("list_deleted_entries_json");
    assert_eq!(final_list, "[]");
}

#[test]
fn entry_purge_refuses_live() {
    let api = api();
    let book_id = api.create_book("DB".into()).unwrap();
    let entry_id = api.add_entry(book_id.clone(), "{}".into()).unwrap();
    // entry n'est pas soft-deleted → purge refuse
    assert!(api.purge_entry(book_id, entry_id).is_err());
}

#[test]
fn entry_delete_twice_is_not_found() {
    let api = api();
    let book_id = api.create_book("DB".into()).unwrap();
    let entry_id = api.add_entry(book_id.clone(), "{}".into()).unwrap();
    api.delete_entry(book_id.clone(), entry_id.clone()).unwrap();
    // second delete sur entry déjà soft-deleted → NotFound
    assert!(api.delete_entry(book_id, entry_id).is_err());
}
