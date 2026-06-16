use pinkha::application::book_use_cases::{create_book, delete_book, get_book};
use pinkha::application::error::PinkhaError;
use pinkha::application::use_cases::{create_leaf, delete_leaf, get_leaf};
use pinkha::domain::book::{Property, PropertyType};
use pinkha::domain::leaf::InlineText;
use pinkha::infrastructure::book_store::BookStore;
use pinkha::infrastructure::json_store::JsonStore;
use uuid::Uuid;

fn leaf_store_temp() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("pinkha_del_leaf_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn book_store_temp() -> BookStore {
    let dir = std::env::temp_dir().join(format!("pinkha_del_book_{}", Uuid::new_v4()));
    BookStore::new(dir).unwrap()
}

fn inlines(s: &str) -> Vec<InlineText> {
    vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }]
}

// ── delete_leaf ────────────────────────────────────────────────────────

#[test]
fn test_delete_leaf_existant() {
    let store = leaf_store_temp();
    let doc = create_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        "À supprimer",
    )
    .unwrap();
    let id = doc.id;

    delete_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        id,
    )
    .unwrap();

    assert!(matches!(
        get_leaf(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
            id
        ),
        Err(PinkhaError::NotFound(_))
    ));
}

#[test]
fn test_delete_leaf_inexistant_retourne_non_trouve() {
    let store = leaf_store_temp();
    let faux_id = Uuid::new_v4();

    let result = delete_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        faux_id,
    );
    assert!(matches!(result, Err(PinkhaError::NotFound(_))));
}

#[test]
fn test_delete_leaf_ne_supprime_pas_les_autres() {
    let store = leaf_store_temp();
    let leaf_a = create_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        "A",
    )
    .unwrap();
    let leaf_b = create_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        "B",
    )
    .unwrap();

    delete_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        leaf_a.id,
    )
    .unwrap();

    assert!(matches!(
        get_leaf(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
            leaf_a.id
        ),
        Err(PinkhaError::NotFound(_))
    ));
    assert!(
        get_leaf(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
            leaf_b.id
        )
        .is_ok()
    );
}

// ── delete_book ────────────────────────────────────────────────────────

#[test]
fn test_delete_book_existante() {
    let store = book_store_temp();
    let prop = Property::new("Titre", PropertyType::Title);
    let db = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        inlines("À supprimer"),
        vec![prop],
    )
    .unwrap();
    let id = db.id;

    delete_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        id,
    )
    .unwrap();

    assert!(matches!(
        get_book(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
            id
        ),
        Err(PinkhaError::NotFound(_))
    ));
}

#[test]
fn test_delete_book_inexistante_retourne_non_trouve() {
    let store = book_store_temp();
    let faux_id = Uuid::new_v4();

    let result = delete_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        faux_id,
    );
    assert!(matches!(result, Err(PinkhaError::NotFound(_))));
}

#[test]
fn test_delete_book_ne_supprime_pas_les_autres() {
    let store = book_store_temp();
    let book_a = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        inlines("A"),
        vec![],
    )
    .unwrap();
    let book_b = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        inlines("B"),
        vec![],
    )
    .unwrap();

    delete_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        book_a.id,
    )
    .unwrap();

    assert!(matches!(
        get_book(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
            book_a.id
        ),
        Err(PinkhaError::NotFound(_))
    ));
    assert!(
        get_book(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
            book_b.id
        )
        .is_ok()
    );
}
