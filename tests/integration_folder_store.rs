use pinkha::application::shelf_repository::ShelfRepository;
use pinkha::infrastructure::sqlite_shelf_store::SqliteShelfStore;
use uuid::Uuid;

fn store() -> SqliteShelfStore {
    SqliteShelfStore::in_memory().expect("create in-memory store")
}

#[test]
fn create_root_shelf() {
    let s = store();
    let f = s.create("Inbox", None).expect("create");
    assert_eq!(f.name, "Inbox");
    assert!(f.parent_id.is_none());
}

#[test]
fn create_nested_shelf() {
    let s = store();
    let parent = s.create("Parent", None).expect("create parent");
    let child = s.create("Child", Some(parent.id)).expect("create child");
    assert_eq!(child.parent_id, Some(parent.id));
}

#[test]
fn get_existing_shelf() {
    let s = store();
    let f = s.create("X", None).expect("create");
    let loaded = s.get(f.id).expect("get");
    assert_eq!(loaded.id, f.id);
    assert_eq!(loaded.name, "X");
}

#[test]
fn get_missing_shelf_returns_not_found() {
    let s = store();
    let err = s.get(Uuid::new_v4()).expect_err("should be missing");
    assert!(matches!(
        err,
        pinkha::application::error::PinkhaError::NotFound(_)
    ));
}

#[test]
fn list_returns_all_shelves_sorted_by_name() {
    let s = store();
    s.create("Zebra", None).expect("z");
    s.create("Alpha", None).expect("a");
    s.create("Mike", None).expect("m");
    let metas = s.list().expect("list");
    assert_eq!(metas.len(), 3);
    let names: Vec<_> = metas.iter().map(|m| m.name.clone()).collect();
    assert_eq!(names, vec!["Alpha", "Mike", "Zebra"]);
}

#[test]
fn list_excludes_deleted_shelves() {
    let s = store();
    let f = s.create("Doomed", None).expect("create");
    s.create("Keep", None).expect("keep");
    s.delete(f.id).expect("delete");
    let metas = s.list().expect("list");
    assert_eq!(metas.len(), 1);
    assert_eq!(metas[0].name, "Keep");
}

#[test]
fn rename_changes_name_and_updated_at() {
    let s = store();
    let f = s.create("Old", None).expect("create");
    let before = f.updated_at.clone();
    std::thread::sleep(std::time::Duration::from_millis(10));
    s.rename(f.id, "New").expect("rename");
    let loaded = s.get(f.id).expect("get");
    assert_eq!(loaded.name, "New");
    assert!(loaded.updated_at >= before);
}

#[test]
fn rename_missing_shelf_fails() {
    let s = store();
    let err = s.rename(Uuid::new_v4(), "X").expect_err("should fail");
    assert!(matches!(
        err,
        pinkha::application::error::PinkhaError::NotFound(_)
    ));
}

#[test]
fn rename_deleted_shelf_fails() {
    let s = store();
    let f = s.create("Doomed", None).expect("create");
    s.delete(f.id).expect("delete");
    let err = s.rename(f.id, "X").expect_err("should fail");
    assert!(matches!(
        err,
        pinkha::application::error::PinkhaError::NotFound(_)
    ));
}

#[test]
fn delete_marks_shelf_as_deleted() {
    let s = store();
    let f = s.create("Doomed", None).expect("create");
    s.delete(f.id).expect("delete");
    let err = s.get(f.id).expect_err("should be missing");
    assert!(matches!(
        err,
        pinkha::application::error::PinkhaError::NotFound(_)
    ));
}

#[test]
fn delete_missing_shelf_fails() {
    let s = store();
    let err = s.delete(Uuid::new_v4()).expect_err("should fail");
    assert!(matches!(
        err,
        pinkha::application::error::PinkhaError::NotFound(_)
    ));
}

#[test]
fn delete_twice_fails_second_time() {
    let s = store();
    let f = s.create("X", None).expect("create");
    s.delete(f.id).expect("first delete");
    let err = s.delete(f.id).expect_err("second delete should fail");
    assert!(matches!(
        err,
        pinkha::application::error::PinkhaError::NotFound(_)
    ));
}

#[test]
fn delete_reparents_child_shelves() {
    let s = store();
    let grand = s.create("Grand", None).expect("grand");
    let parent = s.create("Parent", Some(grand.id)).expect("parent");
    let child = s.create("Child", Some(parent.id)).expect("child");
    s.delete(parent.id).expect("delete parent");
    let reloaded = s.get(child.id).expect("child still exists");
    assert_eq!(reloaded.parent_id, Some(grand.id));
}

#[test]
fn delete_root_shelf_reparents_children_to_root() {
    let s = store();
    let parent = s.create("Parent", None).expect("parent");
    let child = s.create("Child", Some(parent.id)).expect("child");
    s.delete(parent.id).expect("delete");
    let reloaded = s.get(child.id).expect("child still exists");
    assert!(reloaded.parent_id.is_none());
}

#[test]
fn move_shelf_to_new_parent() {
    let s = store();
    let a = s.create("A", None).expect("a");
    let b = s.create("B", None).expect("b");
    s.move_shelf(a.id, Some(b.id)).expect("move");
    let reloaded = s.get(a.id).expect("get");
    assert_eq!(reloaded.parent_id, Some(b.id));
}

#[test]
fn move_shelf_to_root() {
    let s = store();
    let parent = s.create("Parent", None).expect("parent");
    let child = s.create("Child", Some(parent.id)).expect("child");
    s.move_shelf(child.id, None).expect("move to root");
    let reloaded = s.get(child.id).expect("get");
    assert!(reloaded.parent_id.is_none());
}

#[test]
fn move_missing_shelf_fails() {
    let s = store();
    let err = s
        .move_shelf(Uuid::new_v4(), None)
        .expect_err("should fail");
    assert!(matches!(
        err,
        pinkha::application::error::PinkhaError::NotFound(_)
    ));
}

#[test]
fn move_deleted_shelf_fails() {
    let s = store();
    let f = s.create("X", None).expect("create");
    s.delete(f.id).expect("delete");
    let err = s.move_shelf(f.id, None).expect_err("should fail");
    assert!(matches!(
        err,
        pinkha::application::error::PinkhaError::NotFound(_)
    ));
}

#[test]
fn new_on_disk_creates_file_and_persists() {
    let path = std::env::temp_dir().join(format!("pinkha-shelves-{}.db", Uuid::new_v4()));
    let path_str = path.to_str().expect("utf8 path").to_string();
    let id = {
        let s = SqliteShelfStore::new(&path_str).expect("open store");
        let f = s.create("Persisted", None).expect("create");
        f.id
    };
    let s2 = SqliteShelfStore::new(&path_str).expect("reopen store");
    let f = s2.get(id).expect("still there after reopen");
    assert_eq!(f.name, "Persisted");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn new_on_invalid_path_fails() {
    let result = SqliteShelfStore::new("/nonexistent_dir_xyz/no.db");
    assert!(result.is_err());
}

/// Regression: when a shelf is deleted, orphaned leaves are moved to root by
/// updating `leaves.shelf_id = NULL`. Without syncing the JSON `data` blob,
/// a subsequent `save()` on one of those leaves (e.g. rename) would read
/// the stale blob and rewrite the deleted shelf id back to the column,
/// leaving the leaf pointing to a shelf that no longer exists.
#[test]
fn shelf_delete_orphans_survive_leaf_save() {
    use pinkha::application::repository::LeafRepository;
    use pinkha::domain::leaf::{InlineText, Leaf};
    use pinkha::infrastructure::sqlite_leaf_store::SqliteLeafStore;

    let path = std::env::temp_dir().join(format!("pinkha-cross-{}.db", Uuid::new_v4()));
    let path_str = path.to_str().expect("utf8 path").to_string();

    let shelf_store = SqliteShelfStore::new(&path_str).expect("open shelf store");
    let leaf_store = SqliteLeafStore::new(&path_str).expect("open leaf store");

    // Create a shelf and a leaf, park the leaf in the shelf.
    let shelf = shelf_store.create("Doomed", None).expect("create shelf");
    let mut doc = Leaf::new(vec![InlineText {
        content: "Résident".to_string(),
        styles: vec![],
    }]);
    leaf_store.save(&doc).expect("save leaf");
    leaf_store
        .move_to_shelf(doc.id, Some(shelf.id))
        .expect("move to shelf");

    // Delete the shelf → the leaf's column should now be NULL, and the
    // blob synced (otherwise the next save would resurrect the id).
    shelf_store.delete(shelf.id).expect("delete shelf");

    // Simulate the rename flow: load, mutate title, save.
    doc = leaf_store.load(doc.id).expect("load after shelf delete");
    assert_eq!(doc.shelf_id, None, "column NULL after shelf delete");
    doc.title = vec![InlineText {
        content: "Renommé après suppression du shelf".to_string(),
        styles: vec![],
    }];
    leaf_store.save(&doc).expect("save after rename");

    // Reload and check the leaf is still at root (no zombie shelf id).
    let after = leaf_store.load(doc.id).expect("final load");
    assert_eq!(
        after.shelf_id, None,
        "leaf stays at root after shelf.delete + leaf save"
    );

    let _ = std::fs::remove_file(&path);
}
