//! Tests d'intégration pour la corbeille (soft delete + restore + purge).
//!
//! Exerce les FFI `list_deleted_*`, `restore_*`, `purge_*` pour les 4 types :
//! documents, databases, folders, entries.

use pinkha::ffi::PinkhaApi;

fn api() -> PinkhaApi {
    PinkhaApi::new(":memory:".into()).unwrap()
}

// ── Documents ────────────────────────────────────────────────────────────────

#[test]
fn document_soft_delete_restore_purge_roundtrip() {
    let api = api();
    let id = api.create_document("À supprimer".into()).unwrap();

    // delete (soft) → disparaît de list_documents, apparaît dans list_deleted_documents
    api.delete_document(id.clone()).unwrap();
    assert_eq!(api.list_documents().unwrap().len(), 0);
    let deleted = api.list_deleted_documents().unwrap();
    assert_eq!(deleted.len(), 1);
    assert_eq!(deleted[0].id, id);

    // restore → revient dans la liste active, disparaît de la corbeille
    api.restore_document(id.clone()).unwrap();
    assert_eq!(api.list_documents().unwrap().len(), 1);
    assert_eq!(api.list_deleted_documents().unwrap().len(), 0);

    // re-delete puis purge → hard delete : ni dans active, ni dans corbeille
    api.delete_document(id.clone()).unwrap();
    api.purge_document(id.clone()).unwrap();
    assert_eq!(api.list_documents().unwrap().len(), 0);
    assert_eq!(api.list_deleted_documents().unwrap().len(), 0);
}

#[test]
fn document_purge_refuses_live_document() {
    let api = api();
    let id = api.create_document("Encore vivant".into()).unwrap();
    // purge un doc qui n'est pas en corbeille → InvalidOperation
    assert!(api.purge_document(id).is_err());
}

#[test]
fn document_restore_unknown_id_fails() {
    let api = api();
    let bogus = uuid::Uuid::new_v4().to_string();
    assert!(api.restore_document(bogus).is_err());
}

// ── Databases ────────────────────────────────────────────────────────────────

#[test]
fn database_soft_delete_restore_purge_roundtrip() {
    let api = api();
    let id = api.create_database("Tasks".into()).unwrap();

    api.delete_database(id.clone()).unwrap();
    assert_eq!(api.list_databases().unwrap().len(), 0);
    assert_eq!(api.list_deleted_databases().unwrap().len(), 1);

    api.restore_database(id.clone()).unwrap();
    assert_eq!(api.list_databases().unwrap().len(), 1);
    assert_eq!(api.list_deleted_databases().unwrap().len(), 0);

    api.delete_database(id.clone()).unwrap();
    api.purge_database(id).unwrap();
    assert_eq!(api.list_deleted_databases().unwrap().len(), 0);
}

#[test]
fn database_purge_refuses_live() {
    let api = api();
    let id = api.create_database("Live".into()).unwrap();
    assert!(api.purge_database(id).is_err());
}

// ── Folders ──────────────────────────────────────────────────────────────────

#[test]
fn folder_soft_delete_restore_purge_roundtrip() {
    let api = api();
    let folder = api.create_folder("Box".into(), None).unwrap();

    api.delete_folder(folder.id.clone()).unwrap();
    assert_eq!(api.list_folders().unwrap().len(), 0);
    assert_eq!(api.list_deleted_folders().unwrap().len(), 1);

    api.restore_folder(folder.id.clone()).unwrap();
    assert_eq!(api.list_folders().unwrap().len(), 1);

    api.delete_folder(folder.id.clone()).unwrap();
    api.purge_folder(folder.id).unwrap();
    assert_eq!(api.list_deleted_folders().unwrap().len(), 0);
}

#[test]
fn folder_purge_refuses_live() {
    let api = api();
    let folder = api.create_folder("Live".into(), None).unwrap();
    assert!(api.purge_folder(folder.id).is_err());
}

// ── Entries ──────────────────────────────────────────────────────────────────

#[test]
fn entry_soft_delete_restore_purge_roundtrip() {
    let api = api();
    let db_id = api.create_database("DB".into()).unwrap();
    let entry_id = api
        .add_entry(db_id.clone(), "{}".into())
        .expect("add_entry should succeed with empty values");

    // delete entry (soft) → disparaît du query mais reste dans le JSON
    api.delete_entry(db_id.clone(), entry_id.clone()).unwrap();
    let deleted_list_json = api
        .list_deleted_entries_json(db_id.clone())
        .expect("list_deleted_entries_json");
    assert!(deleted_list_json.contains(&entry_id));

    // restore → réapparaît
    api.restore_entry(db_id.clone(), entry_id.clone()).unwrap();
    let after_restore = api
        .list_deleted_entries_json(db_id.clone())
        .expect("list_deleted_entries_json");
    assert_eq!(after_restore, "[]");

    // re-delete + purge → hard delete
    api.delete_entry(db_id.clone(), entry_id.clone()).unwrap();
    api.purge_entry(db_id.clone(), entry_id.clone()).unwrap();
    let final_list = api
        .list_deleted_entries_json(db_id)
        .expect("list_deleted_entries_json");
    assert_eq!(final_list, "[]");
}

#[test]
fn entry_purge_refuses_live() {
    let api = api();
    let db_id = api.create_database("DB".into()).unwrap();
    let entry_id = api.add_entry(db_id.clone(), "{}".into()).unwrap();
    // entry n'est pas soft-deleted → purge refuse
    assert!(api.purge_entry(db_id, entry_id).is_err());
}

#[test]
fn entry_delete_twice_is_not_found() {
    let api = api();
    let db_id = api.create_database("DB".into()).unwrap();
    let entry_id = api.add_entry(db_id.clone(), "{}".into()).unwrap();
    api.delete_entry(db_id.clone(), entry_id.clone()).unwrap();
    // second delete sur entry déjà soft-deleted → NotFound
    assert!(api.delete_entry(db_id, entry_id).is_err());
}
