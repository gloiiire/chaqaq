use chaqaq::application::database_use_cases::{
    column_aggregate, add_entry, add_view, create_database, evaluate_rollups,
    list_databases, update_entry, get_database, requete, grouped_query,
    delete_entry,
};
use chaqaq::domain::database::{
    Aggregate, FilterCondition, Filter, Order, Property, PropertyType, Sort, ViewType,
    PropertyValue, View,
};
use chaqaq::domain::document::InlineText;
use chaqaq::infrastructure::database_store::DatabaseStore;
use std::collections::HashMap;
use uuid::Uuid;

fn store_temp() -> DatabaseStore {
    let dir = std::env::temp_dir().join(format!("chaqaq_db_integ_{}", Uuid::new_v4()));
    DatabaseStore::nouveau(dir).unwrap()
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
fn test_creer_et_get_database() {
    let store = store_temp();
    let props = vec![Property::new("Nom", PropertyType::Title)];
    let db = create_database(&store, title("Projets"), props).unwrap();
    let chargee = get_database(&store, db.id).unwrap();
    assert_eq!(chargee.id, db.id);
    assert_eq!(chargee.properties.len(), 1);
}

#[test]
fn test_add_entry_persiste() {
    let store = store_temp();
    let prop = Property::new("Score", PropertyType::Number);
    let prop_id = prop.id;
    let db = create_database(&store, title("Scores"), vec![prop]).unwrap();

    add_entry(&store, db.id, entry_nombre(prop_id, 10.0)).unwrap();
    add_entry(&store, db.id, entry_nombre(prop_id, 20.0)).unwrap();

    let chargee = get_database(&store, db.id).unwrap();
    assert_eq!(chargee.entries.len(), 2);
}

#[test]
fn test_filtrer_entries_par_valeur() {
    let store = store_temp();
    let prop = Property::new("Statut", PropertyType::Text);
    let prop_id = prop.id;
    let db = create_database(&store, title("Tâches"), vec![prop]).unwrap();

    let mut v1 = HashMap::new();
    v1.insert(prop_id, PropertyValue::Text("En cours".to_string()));
    let mut v2 = HashMap::new();
    v2.insert(prop_id, PropertyValue::Text("Terminé".to_string()));
    add_entry(&store, db.id, v1).unwrap();
    add_entry(&store, db.id, v2).unwrap();

    // ajoute une vue avec filtre
    let mut vue = View::new("En cours seulement", ViewType::Table);
    vue.filters.push(Filter {
        property_id: prop_id,
        condition: FilterCondition::Contains("cours".to_string()),
    });
    let vue = add_view(&store, db.id, vue).unwrap();

    let resultats = requete(&store, db.id, vue.id).unwrap();
    assert_eq!(resultats.len(), 1);
}

#[test]
fn test_trier_entries_par_nombre() {
    let store = store_temp();
    let prop = Property::new("Priorité", PropertyType::Number);
    let prop_id = prop.id;
    let db = create_database(&store, title("Items"), vec![prop]).unwrap();

    add_entry(&store, db.id, entry_nombre(prop_id, 3.0)).unwrap();
    add_entry(&store, db.id, entry_nombre(prop_id, 1.0)).unwrap();
    add_entry(&store, db.id, entry_nombre(prop_id, 2.0)).unwrap();

    let mut vue = View::new("Par priorité", ViewType::Table);
    vue.sorts.push(Sort::by_property(prop_id, Order::Ascending));
    let vue = add_view(&store, db.id, vue).unwrap();

    let resultats = requete(&store, db.id, vue.id).unwrap();
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
    let db = create_database(&store, title("Notes"), vec![prop]).unwrap();

    let entry = add_entry(&store, db.id, entry_nombre(prop_id, 5.0)).unwrap();

    update_entry(&store, db.id, entry.id, entry_nombre(prop_id, 10.0)).unwrap();
    let db_modifiee = get_database(&store, db.id).unwrap();
    assert_eq!(
        db_modifiee.entries[0].values[&prop_id],
        PropertyValue::Number(10.0)
    );

    delete_entry(&store, db.id, entry.id).unwrap();
    let db_finale = get_database(&store, db.id).unwrap();
    assert!(db_finale.entries.is_empty());
}

#[test]
fn test_list_databases() {
    let store = store_temp();
    create_database(&store, title("DB1"), vec![]).unwrap();
    create_database(&store, title("DB2"), vec![]).unwrap();
    let metas = list_databases(&store).unwrap();
    assert_eq!(metas.len(), 2);
}

// ── Relations & Rollups ──────────────────────────────────────────────────────

#[test]
fn test_rollup_compte_entries_liees() {
    let store = store_temp();

    // Database Tâches
    let prop_title = Property::new("Titre", PropertyType::Title);
    let db_taches = create_database(&store, title("Tâches"), vec![prop_title]).unwrap();

    // Ajoute 2 tâches
    let mut v1 = HashMap::new();
    v1.insert(
        db_taches.properties[0].id,
        PropertyValue::Title(title("T1")),
    );
    let t1 = add_entry(&store, db_taches.id, v1).unwrap();

    let mut v2 = HashMap::new();
    v2.insert(
        db_taches.properties[0].id,
        PropertyValue::Title(title("T2")),
    );
    let t2 = add_entry(&store, db_taches.id, v2).unwrap();

    // Database Projets avec Relation → Tâches et Rollup (Count)
    let prop_rel = Property::new(
        "Tâches liées",
        PropertyType::Relation {
            db_id: db_taches.id,
        },
    );
    let prop_nb = Property::new(
        "Nb tâches",
        PropertyType::Rollup {
            relation_prop_id: prop_rel.id,
            target_prop_id: db_taches.properties[0].id,
            aggregate: Aggregate::Count,
        },
    );
    let nb_id = prop_nb.id;
    let rel_id = prop_rel.id;
    let db_projets = create_database(&store, title("Projets"), vec![prop_rel, prop_nb]).unwrap();

    // Ajoute un projet lié aux 2 tâches
    let mut vp = HashMap::new();
    vp.insert(rel_id, PropertyValue::Relation(vec![t1.id, t2.id]));
    let entry = add_entry(&store, db_projets.id, vp).unwrap();

    // Évalue les rollups
    let db = get_database(&store, db_projets.id).unwrap();
    let enrichies = evaluate_rollups(&store, &db, vec![entry]).unwrap();

    assert_eq!(enrichies[0].values[&nb_id], PropertyValue::Number(2.0));
}

#[test]
fn test_column_aggregate_somme() {
    let store = store_temp();
    let prop = Property::new("Score", PropertyType::Number);
    let prop_id = prop.id;
    let db = create_database(&store, title("Scores"), vec![prop]).unwrap();

    add_entry(&store, db.id, entry_nombre(prop_id, 10.0)).unwrap();
    add_entry(&store, db.id, entry_nombre(prop_id, 20.0)).unwrap();
    add_entry(&store, db.id, entry_nombre(prop_id, 30.0)).unwrap();

    let total = column_aggregate(&store, db.id, prop_id, Aggregate::Sum).unwrap();
    assert_eq!(total, PropertyValue::Number(60.0));
}

#[test]
fn test_column_aggregate_moyenne() {
    let store = store_temp();
    let prop = Property::new("Note", PropertyType::Number);
    let prop_id = prop.id;
    let db = create_database(&store, title("Notes"), vec![prop]).unwrap();

    add_entry(&store, db.id, entry_nombre(prop_id, 8.0)).unwrap();
    add_entry(&store, db.id, entry_nombre(prop_id, 12.0)).unwrap();

    let moy = column_aggregate(&store, db.id, prop_id, Aggregate::Average).unwrap();
    assert_eq!(moy, PropertyValue::Number(10.0));
}

// ── Groupment ───────────────────────────────────────────────────────────────

#[test]
fn test_grouped_query_par_selection() {
    let store = store_temp();
    let prop = Property::new(
        "Statut",
        PropertyType::Selection(vec!["En cours".into(), "Terminé".into()]),
    );
    let prop_id = prop.id;
    let db = create_database(&store, title("Tâches"), vec![prop]).unwrap();
    let view_id = db.views[0].id;

    let statuts = ["En cours", "Terminé", "En cours", "En cours"];
    for s in statuts {
        let mut v = HashMap::new();
        v.insert(prop_id, PropertyValue::Selection(Some(s.to_string())));
        add_entry(&store, db.id, v).unwrap();
    }

    let groups = grouped_query(&store, db.id, view_id, prop_id).unwrap();
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
    let db = create_database(&store, title("Items"), vec![prop]).unwrap();
    let view_id = db.views[0].id;

    // une entrée avec valeur, une sans
    let mut v1 = HashMap::new();
    v1.insert(prop_id, PropertyValue::Text("Actif".to_string()));
    add_entry(&store, db.id, v1).unwrap();
    add_entry(&store, db.id, HashMap::new()).unwrap(); // Empty

    let groups = grouped_query(&store, db.id, view_id, prop_id).unwrap();
    assert_eq!(groups.len(), 2);
    // Empty trié en dernier
    assert_eq!(groups.last().unwrap().value, PropertyValue::Empty);
}

// ── SortSource : date auto, manuelle, hybride ─────────────────────────────────

#[test]
fn test_tri_by_creation_auto() {
    let store = store_temp();
    let db = create_database(&store, title("Journal"), vec![]).unwrap();
    // 3 entrées créées avec des created_at manuellement espacés pour le test
    let mut e1 = chaqaq::domain::database::Entry::new(HashMap::new());
    e1.created_at = "2023-01-01T00:00:00+00:00".to_string();
    let mut e2 = chaqaq::domain::database::Entry::new(HashMap::new());
    e2.created_at = "2023-06-15T00:00:00+00:00".to_string();
    let mut e3 = chaqaq::domain::database::Entry::new(HashMap::new());
    e3.created_at = "2022-12-01T00:00:00+00:00".to_string();

    // Persiste via save direct
    use chaqaq::application::database_repository::DatabaseRepository;
    let mut db = get_database(&store, db.id).unwrap();
    db.entries = vec![e1.clone(), e2.clone(), e3.clone()];
    store.save(&db).unwrap();

    let mut vue = View::new("Chronologique", ViewType::Table);
    vue.sorts.push(Sort::by_creation(Order::Ascending));
    let vue = add_view(&store, db.id, vue).unwrap();

    let resultats = requete(&store, db.id, vue.id).unwrap();
    assert_eq!(resultats[0].created_at, "2022-12-01T00:00:00+00:00");
    assert_eq!(resultats[1].created_at, "2023-01-01T00:00:00+00:00");
    assert_eq!(resultats[2].created_at, "2023-06-15T00:00:00+00:00");
}

#[test]
fn test_tri_manual_then_creation_cas_journal() {
    let store = store_temp();
    let prop_date = Property::new("Date", PropertyType::Date);
    let date_id = prop_date.id;
    let db = create_database(&store, title("Journal"), vec![prop_date]).unwrap();

    // Note ancienne : date manuelle renseignée, created_at récent (import)
    let mut v_ancienne = HashMap::new();
    v_ancienne.insert(date_id, PropertyValue::Date("2020-05-10".to_string()));
    let mut e_ancienne = chaqaq::domain::database::Entry::new(v_ancienne);
    e_ancienne.created_at = "2024-01-01T00:00:00+00:00".to_string(); // importée récemment

    // Note new : pas de date manuelle, created_at = date réelle d'écriture
    let mut e_new = chaqaq::domain::database::Entry::new(HashMap::new());
    e_new.created_at = "2024-06-01T00:00:00+00:00".to_string();

    use chaqaq::application::database_repository::DatabaseRepository;
    let mut db = get_database(&store, db.id).unwrap();
    db.entries = vec![e_new.clone(), e_ancienne.clone()]; // order inversé intentionnel
    store.save(&db).unwrap();

    // View avec tri ManualThenCreated croissant
    let mut vue = View::new("Chronologique", ViewType::Table);
    vue.sorts
        .push(Sort::manual_then_creation(date_id, Order::Ascending));
    let vue = add_view(&store, db.id, vue).unwrap();

    let resultats = requete(&store, db.id, vue.id).unwrap();
    // L'ancienne note (date manuelle 2020) doit passer AVANT la new (created_at 2024)
    let date_premiere = resultats[0].values.get(&date_id);
    assert_eq!(
        date_premiere,
        Some(&PropertyValue::Date("2020-05-10".to_string()))
    );
}
