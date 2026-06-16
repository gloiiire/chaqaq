use pinkha::application::book_use_cases::{
    add_entry, add_view, column_aggregate, create_book, delete_entry, evaluate_rollups,
    get_book, grouped_query, list_books, query, update_entry,
};
use pinkha::domain::book::{
    Aggregate, Filter, FilterCondition, Order, Property, PropertyType, PropertyValue, Sort, View,
    ViewType,
};
use pinkha::domain::leaf::InlineText;
use pinkha::infrastructure::book_store::BookStore;
use std::collections::HashMap;
use uuid::Uuid;

fn store_temp() -> BookStore {
    let dir = std::env::temp_dir().join(format!("pinkha_book_integ_{}", Uuid::new_v4()));
    BookStore::new(dir).unwrap()
}

fn title(s: &str) -> Vec<InlineText> {
    vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }]
}

fn entry_nombre(prop_id: Uuid, n: f64) -> HashMap<Uuid, PropertyValue> {
    let mut map = HashMap::new();
    map.insert(prop_id, PropertyValue::Number(n));
    map
}

#[test]
fn test_creer_et_get_book() {
    let store = store_temp();
    let props = vec![Property::new("Nom", PropertyType::Title)];
    let db = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("Projets"),
        props,
    )
    .unwrap();
    let chargee = get_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
    )
    .unwrap();
    assert_eq!(chargee.id, db.id);
    assert_eq!(chargee.properties.len(), 1);
}

#[test]
fn test_add_entry_persiste() {
    let store = store_temp();
    let prop = Property::new("Score", PropertyType::Number);
    let prop_id = prop.id;
    let db = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("Scores"),
        vec![prop],
    )
    .unwrap();

    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        entry_nombre(prop_id, 10.0),
    )
    .unwrap();
    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        entry_nombre(prop_id, 20.0),
    )
    .unwrap();

    let chargee = get_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
    )
    .unwrap();
    assert_eq!(chargee.entries.len(), 2);
}

#[test]
fn test_filtrer_entries_par_valeur() {
    let store = store_temp();
    let prop = Property::new("Statut", PropertyType::Text);
    let prop_id = prop.id;
    let db = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("Tâches"),
        vec![prop],
    )
    .unwrap();

    let mut v1 = HashMap::new();
    v1.insert(prop_id, PropertyValue::Text("En cours".to_string()));
    let mut v2 = HashMap::new();
    v2.insert(prop_id, PropertyValue::Text("Terminé".to_string()));
    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        v1,
    )
    .unwrap();
    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        v2,
    )
    .unwrap();

    // add a view with a filter
    let mut vue = View::new("En cours seulement", ViewType::Table);
    vue.filters.push(Filter {
        property_id: prop_id,
        condition: FilterCondition::Contains("cours".to_string()),
    });
    let vue = add_view(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        vue,
    )
    .unwrap();

    let resultats = query(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        vue.id,
    )
    .unwrap();
    assert_eq!(resultats.len(), 1);
}

#[test]
fn test_trier_entries_par_nombre() {
    let store = store_temp();
    let prop = Property::new("Priorité", PropertyType::Number);
    let prop_id = prop.id;
    let db = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("Items"),
        vec![prop],
    )
    .unwrap();

    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        entry_nombre(prop_id, 3.0),
    )
    .unwrap();
    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        entry_nombre(prop_id, 1.0),
    )
    .unwrap();
    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        entry_nombre(prop_id, 2.0),
    )
    .unwrap();

    let mut vue = View::new("Par priorité", ViewType::Table);
    vue.sorts.push(Sort::by_property(prop_id, Order::Ascending));
    let vue = add_view(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        vue,
    )
    .unwrap();

    let resultats = query(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        vue.id,
    )
    .unwrap();
    let values: Vec<f64> = resultats
        .iter()
        .map(|e| match e.values.get(&prop_id).unwrap() {
            PropertyValue::Number(n) => *n,
            _ => panic!("valeur inattendue"),
        })
        .collect();
    assert_eq!(values, vec![1.0, 2.0, 3.0]);
}

#[test]
fn test_modifier_et_delete_entry() {
    let store = store_temp();
    let prop = Property::new("Note", PropertyType::Number);
    let prop_id = prop.id;
    let db = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("Notes"),
        vec![prop],
    )
    .unwrap();

    let entry = add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        entry_nombre(prop_id, 5.0),
    )
    .unwrap();

    update_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        entry.id,
        entry_nombre(prop_id, 10.0),
    )
    .unwrap();
    let book_modifiee = get_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
    )
    .unwrap();
    assert_eq!(
        book_modifiee.entries[0].values[&prop_id],
        PropertyValue::Number(10.0)
    );

    delete_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        entry.id,
    )
    .unwrap();
    let book_finale = get_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
    )
    .unwrap();
    // Soft delete: the row stays but is marked deleted_at. Use `is_deleted()`
    // to assert it's hidden from active views without losing the data.
    assert_eq!(book_finale.entries.len(), 1);
    assert!(book_finale.entries[0].is_deleted());
}

#[test]
fn test_list_books() {
    let store = store_temp();
    create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("DB1"),
        vec![],
    )
    .unwrap();
    create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("DB2"),
        vec![],
    )
    .unwrap();
    let metas = list_books(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
    )
    .unwrap();
    assert_eq!(metas.len(), 2);
}

// ── Relations & Rollups ──────────────────────────────────────────────────────

#[test]
fn test_rollup_compte_entries_liees() {
    let store = store_temp();

    // Tasks book
    let prop_title = Property::new("Titre", PropertyType::Title);
    let book_taches = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("Tâches"),
        vec![prop_title],
    )
    .unwrap();

    // Add 2 tasks
    let mut v1 = HashMap::new();
    v1.insert(
        book_taches.properties[0].id,
        PropertyValue::Title(title("T1")),
    );
    let t1 = add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        book_taches.id,
        v1,
    )
    .unwrap();

    let mut v2 = HashMap::new();
    v2.insert(
        book_taches.properties[0].id,
        PropertyValue::Title(title("T2")),
    );
    let t2 = add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        book_taches.id,
        v2,
    )
    .unwrap();

    // Projects book with Relation → Tasks and Rollup (Count)
    let prop_rel = Property::new(
        "Tâches liées",
        PropertyType::Relation {
            book_id: book_taches.id,
        },
    );
    let prop_nb = Property::new(
        "Nb tâches",
        PropertyType::Rollup {
            relation_prop_id: prop_rel.id,
            target_prop_id: book_taches.properties[0].id,
            aggregate: Aggregate::Count,
        },
    );
    let nb_id = prop_nb.id;
    let rel_id = prop_rel.id;
    let book_projets = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("Projets"),
        vec![prop_rel, prop_nb],
    )
    .unwrap();

    // Add a project linked to both tasks
    let mut vp = HashMap::new();
    vp.insert(rel_id, PropertyValue::Relation(vec![t1.id, t2.id]));
    let entry = add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        book_projets.id,
        vp,
    )
    .unwrap();

    // Evaluate rollups
    let db = get_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        book_projets.id,
    )
    .unwrap();
    let enrichies = evaluate_rollups(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        &db,
        vec![entry],
    )
    .unwrap();

    assert_eq!(enrichies[0].values[&nb_id], PropertyValue::Number(2.0));
}

#[test]
fn test_column_aggregate_somme() {
    let store = store_temp();
    let prop = Property::new("Score", PropertyType::Number);
    let prop_id = prop.id;
    let db = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("Scores"),
        vec![prop],
    )
    .unwrap();

    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        entry_nombre(prop_id, 10.0),
    )
    .unwrap();
    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        entry_nombre(prop_id, 20.0),
    )
    .unwrap();
    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        entry_nombre(prop_id, 30.0),
    )
    .unwrap();

    let total = column_aggregate(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        prop_id,
        Aggregate::Sum,
    )
    .unwrap();
    assert_eq!(total, PropertyValue::Number(60.0));
}

#[test]
fn test_column_aggregate_moyenne() {
    let store = store_temp();
    let prop = Property::new("Note", PropertyType::Number);
    let prop_id = prop.id;
    let db = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("Notes"),
        vec![prop],
    )
    .unwrap();

    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        entry_nombre(prop_id, 8.0),
    )
    .unwrap();
    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        entry_nombre(prop_id, 12.0),
    )
    .unwrap();

    let moy = column_aggregate(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        prop_id,
        Aggregate::Average,
    )
    .unwrap();
    assert_eq!(moy, PropertyValue::Number(10.0));
}

// ── Grouping ─────────────────────────────────────────────────────────────────

#[test]
fn test_grouped_query_par_selection() {
    let store = store_temp();
    let prop = Property::new(
        "Statut",
        PropertyType::Selection(vec!["En cours".into(), "Terminé".into()]),
    );
    let prop_id = prop.id;
    let db = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("Tâches"),
        vec![prop],
    )
    .unwrap();
    let view_id = db.views[0].id;

    let statuts = ["En cours", "Terminé", "En cours", "En cours"];
    for s in statuts {
        let mut v = HashMap::new();
        v.insert(prop_id, PropertyValue::Selection(Some(s.to_string())));
        add_entry(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
            db.id,
            v,
        )
        .unwrap();
    }

    let groups = grouped_query(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        view_id,
        prop_id,
    )
    .unwrap();
    assert_eq!(groups.len(), 2);

    let en_cours = groups
        .iter()
        .find(|g| g.value == PropertyValue::Selection(Some("En cours".to_string())))
        .unwrap();
    assert_eq!(en_cours.entries.len(), 3);
}

#[test]
fn test_grouped_query_vide_en_dernier() {
    let store = store_temp();
    let prop = Property::new("Statut", PropertyType::Text);
    let prop_id = prop.id;
    let db = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("Items"),
        vec![prop],
    )
    .unwrap();
    let view_id = db.views[0].id;

    // one entry with a value, one without
    let mut v1 = HashMap::new();
    v1.insert(prop_id, PropertyValue::Text("Actif".to_string()));
    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        v1,
    )
    .unwrap();
    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        HashMap::new(),
    )
    .unwrap(); // Empty

    let groups = grouped_query(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        view_id,
        prop_id,
    )
    .unwrap();
    assert_eq!(groups.len(), 2);
    // Empty group sorts last
    assert_eq!(groups.last().unwrap().value, PropertyValue::Empty);
}

// ── SortSource: auto date, manual, hybrid ────────────────────────────────────

#[test]
fn test_tri_by_creation_auto() {
    let store = store_temp();
    let db = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("Journal"),
        vec![],
    )
    .unwrap();
    // 3 entries with manually spaced created_at values for deterministic ordering
    let mut e1 = pinkha::domain::book::Entry::new(HashMap::new());
    e1.created_at = "2023-01-01T00:00:00+00:00".to_string();
    let mut e2 = pinkha::domain::book::Entry::new(HashMap::new());
    e2.created_at = "2023-06-15T00:00:00+00:00".to_string();
    let mut e3 = pinkha::domain::book::Entry::new(HashMap::new());
    e3.created_at = "2022-12-01T00:00:00+00:00".to_string();

    // Persist via direct save
    use pinkha::application::book_repository::BookRepository;
    let mut db = get_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
    )
    .unwrap();
    db.entries = vec![e1.clone(), e2.clone(), e3.clone()];
    store.save(&db).unwrap();

    let mut vue = View::new("Chronologique", ViewType::Table);
    vue.sorts.push(Sort::by_creation(Order::Ascending));
    let vue = add_view(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        vue,
    )
    .unwrap();

    let resultats = query(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        vue.id,
    )
    .unwrap();
    assert_eq!(resultats[0].created_at, "2022-12-01T00:00:00+00:00");
    assert_eq!(resultats[1].created_at, "2023-01-01T00:00:00+00:00");
    assert_eq!(resultats[2].created_at, "2023-06-15T00:00:00+00:00");
}

#[test]
fn test_tri_manual_then_creation_cas_journal() {
    let store = store_temp();
    let prop_date = Property::new("Date", PropertyType::Date);
    let date_id = prop_date.id;
    let db = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        title("Journal"),
        vec![prop_date],
    )
    .unwrap();

    // Old note: manual date filled in, recent created_at (imported retroactively)
    let mut v_ancienne = HashMap::new();
    v_ancienne.insert(date_id, PropertyValue::Date("2020-05-10".to_string()));
    let mut e_ancienne = pinkha::domain::book::Entry::new(v_ancienne);
    e_ancienne.created_at = "2024-01-01T00:00:00+00:00".to_string(); // imported recently

    // New note: no manual date, created_at = actual writing date
    let mut e_new = pinkha::domain::book::Entry::new(HashMap::new());
    e_new.created_at = "2024-06-01T00:00:00+00:00".to_string();

    use pinkha::application::book_repository::BookRepository;
    let mut db = get_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
    )
    .unwrap();
    db.entries = vec![e_new.clone(), e_ancienne.clone()]; // intentionally reversed order
    store.save(&db).unwrap();

    // View with ManualThenCreated ascending sort
    let mut vue = View::new("Chronologique", ViewType::Table);
    vue.sorts
        .push(Sort::manual_then_creation(date_id, Order::Ascending));
    let vue = add_view(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        vue,
    )
    .unwrap();

    let resultats = query(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        db.id,
        vue.id,
    )
    .unwrap();
    // The old note (manual date 2020) must come BEFORE the new one (created_at 2024)
    let date_premiere = resultats[0].values.get(&date_id);
    assert_eq!(
        date_premiere,
        Some(&PropertyValue::Date("2020-05-10".to_string()))
    );
}
