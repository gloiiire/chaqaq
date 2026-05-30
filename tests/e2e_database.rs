use chaqaq::application::database_use_cases::{
    column_aggregate, add_entry, add_property, add_view, create_database,
    evaluate_rollups, get_database, requete, grouped_query,
};
use chaqaq::application::repository::DocumentRepository;
use chaqaq::application::use_cases::create_document;
use chaqaq::domain::database::{
    Aggregate, FilterCondition, Filter, Order, Property, PropertyType, Sort, ViewType,
    PropertyValue, View,
};
use chaqaq::domain::document::{BlockContent, InlineText};
use chaqaq::infrastructure::database_store::DatabaseStore;
use chaqaq::infrastructure::json_store::JsonStore;
use std::collections::HashMap;
use uuid::Uuid;

fn title(s: &str) -> Vec<InlineText> {
    vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }]
}

fn store_temp() -> (JsonStore, DatabaseStore) {
    let id = Uuid::new_v4();
    let doc_dir = std::env::temp_dir().join(format!("chaqaq_e2e_docs_{id}"));
    let db_dir = std::env::temp_dir().join(format!("chaqaq_e2e_dbs_{id}"));
    std::fs::create_dir_all(&doc_dir).unwrap();
    (
        JsonStore::new(doc_dir),
        DatabaseStore::nouveau(db_dir).unwrap(),
    )
}

#[test]
fn test_flux_complet_database() {
    let (_doc_store, db_store) = store_temp();

    // crée une database avec deux propriétés
    let prop_nom = Property::new("Nom", PropertyType::Title);
    let prop_score = Property::new("Score", PropertyType::Number);
    let nom_id = prop_nom.id;
    let score_id = prop_score.id;

    let db = create_database(&db_store, title("Classement"), vec![prop_nom, prop_score]).unwrap();

    // ajoute des entrées
    let mut v1 = HashMap::new();
    v1.insert(nom_id, PropertyValue::Title(title("Alice")));
    v1.insert(score_id, PropertyValue::Number(95.0));

    let mut v2 = HashMap::new();
    v2.insert(nom_id, PropertyValue::Title(title("Bob")));
    v2.insert(score_id, PropertyValue::Number(82.0));

    let mut v3 = HashMap::new();
    v3.insert(nom_id, PropertyValue::Title(title("Charlie")));
    v3.insert(score_id, PropertyValue::Number(88.0));

    add_entry(&db_store, db.id, v1).unwrap();
    add_entry(&db_store, db.id, v2).unwrap();
    add_entry(&db_store, db.id, v3).unwrap();

    // vue triée par score décroissant
    let mut vue = View::new("Top scores", ViewType::Table);
    vue.sorts
        .push(Sort::by_property(score_id, Order::Descending));
    let vue = add_view(&db_store, db.id, vue).unwrap();

    let resultats = requete(&db_store, db.id, vue.id).unwrap();
    assert_eq!(resultats.len(), 3);
    assert_eq!(
        resultats[0].values[&score_id],
        PropertyValue::Number(95.0)
    );
}

#[test]
fn test_database_liee_a_document() {
    let (doc_store, db_store) = store_temp();

    let db = create_database(&db_store, title("Tâches"), vec![]).unwrap();

    // document qui référence la database via un bloc
    let mut doc = create_document(&doc_store, "Mon projet").unwrap();
    doc.add_block(BlockContent::Database { id: db.id });
    doc_store.save(&doc).unwrap();

    let recharge = doc_store.load(doc.id).unwrap();
    assert!(matches!(
        &recharge.blocks[0].content,
        BlockContent::Database { id } if *id == db.id
    ));
}

#[test]
fn test_vue_avec_filtre_et_tri_combines() {
    let (_doc_store, db_store) = store_temp();

    let prop_statut = Property::new("Statut", PropertyType::Text);
    let prop_priorite = Property::new("Priorité", PropertyType::Number);
    let statut_id = prop_statut.id;
    let priorite_id = prop_priorite.id;

    let db = create_database(
        &db_store,
        title("Backlog"),
        vec![prop_statut, prop_priorite],
    )
    .unwrap();

    let entries = vec![
        ("En cours", 3.0),
        ("Terminé", 1.0),
        ("En cours", 1.0),
        ("Terminé", 2.0),
    ];
    for (s, p) in entries {
        let mut v = HashMap::new();
        v.insert(statut_id, PropertyValue::Text(s.to_string()));
        v.insert(priorite_id, PropertyValue::Number(p));
        add_entry(&db_store, db.id, v).unwrap();
    }

    let mut vue = View::new("En cours par priorité", ViewType::Table);
    vue.filters.push(Filter {
        property_id: statut_id,
        condition: FilterCondition::Equal(PropertyValue::Text("En cours".to_string())),
    });
    vue.sorts
        .push(Sort::by_property(priorite_id, Order::Ascending));
    let vue = add_view(&db_store, db.id, vue).unwrap();

    let resultats = requete(&db_store, db.id, vue.id).unwrap();
    assert_eq!(resultats.len(), 2);
    assert_eq!(
        resultats[0].values[&priorite_id],
        PropertyValue::Number(1.0)
    );
}

#[test]
fn test_add_property_a_database_existante() {
    let (_doc_store, db_store) = store_temp();
    let db = create_database(&db_store, title("Notes"), vec![]).unwrap();
    assert_eq!(
        get_database(&db_store, db.id).unwrap().properties.len(),
        0
    );

    add_property(
        &db_store,
        db.id,
        Property::new("Date", PropertyType::Date),
    )
    .unwrap();
    assert_eq!(
        get_database(&db_store, db.id).unwrap().properties.len(),
        1
    );
}

// ── E2E Relations & Rollups ──────────────────────────────────────────────────

#[test]
fn test_flux_rollup_entre_deux_databases() {
    let (_doc_store, db_store) = store_temp();

    // Sprints (database source des relations)
    let prop_points = Property::new("Points", PropertyType::Number);
    let points_id = prop_points.id;
    let db_sprints = create_database(&db_store, title("Sprints"), vec![prop_points]).unwrap();

    let mut s1 = HashMap::new();
    s1.insert(points_id, PropertyValue::Number(8.0));
    let mut s2 = HashMap::new();
    s2.insert(points_id, PropertyValue::Number(13.0));
    let sprint1 = add_entry(&db_store, db_sprints.id, s1).unwrap();
    let sprint2 = add_entry(&db_store, db_sprints.id, s2).unwrap();

    // Projets avec Relation → Sprints + Rollup (Sum des points)
    let prop_rel = Property::new(
        "Sprints",
        PropertyType::Relation {
            db_id: db_sprints.id,
        },
    );
    let prop_total = Property::new(
        "Total points",
        PropertyType::Rollup {
            relation_prop_id: prop_rel.id,
            target_prop_id: points_id,
            aggregate: Aggregate::Sum,
        },
    );
    let total_id = prop_total.id;
    let rel_id = prop_rel.id;
    let db_projets =
        create_database(&db_store, title("Projets"), vec![prop_rel, prop_total]).unwrap();

    let mut vp = HashMap::new();
    vp.insert(
        rel_id,
        PropertyValue::Relation(vec![sprint1.id, sprint2.id]),
    );
    let projet = add_entry(&db_store, db_projets.id, vp).unwrap();

    let db = get_database(&db_store, db_projets.id).unwrap();
    let enrichies = evaluate_rollups(&db_store, &db, vec![projet]).unwrap();

    assert_eq!(
        enrichies[0].values[&total_id],
        PropertyValue::Number(21.0)
    );
}

// ── E2E Kanban (groupement) ──────────────────────────────────────────────────

#[test]
fn test_flux_kanban_complet() {
    let (_doc_store, db_store) = store_temp();

    let prop_statut = Property::new(
        "Statut",
        PropertyType::Selection(vec!["Todo".into(), "En cours".into(), "Terminé".into()]),
    );
    let statut_id = prop_statut.id;
    let db = create_database(&db_store, title("Backlog"), vec![prop_statut]).unwrap();

    // View Kanban groupée par statut
    let vue_kanban = View::new(
        "Kanban",
        ViewType::Kanban {
            group_by: statut_id,
        },
    );
    let vue_kanban = add_view(&db_store, db.id, vue_kanban).unwrap();

    let tickets = [("Todo", 3), ("En cours", 2), ("Terminé", 1)];
    for (statut, n) in tickets {
        for _ in 0..n {
            let mut v = HashMap::new();
            v.insert(
                statut_id,
                PropertyValue::Selection(Some(statut.to_string())),
            );
            add_entry(&db_store, db.id, v).unwrap();
        }
    }

    let groups = grouped_query(&db_store, db.id, vue_kanban.id, statut_id).unwrap();
    assert_eq!(groups.len(), 3);
    let total: usize = groups.iter().map(|g| g.entries.len()).sum();
    assert_eq!(total, 6);
}

// ── E2E Agrégat colonne ──────────────────────────────────────────────────────

#[test]
fn test_aggregate_min_max_colonne() {
    let (_doc_store, db_store) = store_temp();

    let prop = Property::new("Durée", PropertyType::Number);
    let prop_id = prop.id;
    let db = create_database(&db_store, title("Tâches"), vec![prop]).unwrap();

    for n in [5.0, 1.0, 9.0, 3.0] {
        let mut v = HashMap::new();
        v.insert(prop_id, PropertyValue::Number(n));
        add_entry(&db_store, db.id, v).unwrap();
    }

    let min = column_aggregate(&db_store, db.id, prop_id, Aggregate::Min).unwrap();
    let max = column_aggregate(&db_store, db.id, prop_id, Aggregate::Max).unwrap();

    assert_eq!(min, PropertyValue::Number(1.0));
    assert_eq!(max, PropertyValue::Number(9.0));
}

// ── E2E Journal intime — le cas d'usage fondateur ────────────────────────────

/// Scénario réel : tu importes d'anciennes notes avec des dates que tu as
/// saisies à la main, et tu continues d'écrire de news notes dont la date
/// est auto-générée. Une seule vue, un seul tri, tout dans le bon order.
#[test]
fn test_journal_intime_dates_mixtes() {
    let (_doc_store, db_store) = store_temp();

    let prop_date = Property::new("Date", PropertyType::Date);
    let prop_content = Property::new("Texte", PropertyType::Text);
    let date_id = prop_date.id;
    let content_id = prop_content.id;

    let db = create_database(&db_store, title("Journal"), vec![prop_date, prop_content]).unwrap();

    // — Anciennes notes importées : date manuelle renseignée, created_at = maintenant
    let notes_anciennes = [
        ("2019-03-22", "Première entrée retrouvée"),
        ("2021-08-14", "Une pensée de l'été"),
        ("2020-11-30", "Note de fin novembre"),
    ];
    for (date, texte) in notes_anciennes {
        let mut v = HashMap::new();
        v.insert(date_id, PropertyValue::Date(date.to_string()));
        v.insert(content_id, PropertyValue::Text(texte.to_string()));
        add_entry(&db_store, db.id, v).unwrap();
    }

    // — Nouvelles notes : pas de date manuelle, created_at auto (aujourd'hui ≈ 2024+)
    let notes_news = ["Ce soir il pleut", "Réflexions du matin"];
    for texte in notes_news {
        let mut v = HashMap::new();
        v.insert(content_id, PropertyValue::Text(texte.to_string()));
        add_entry(&db_store, db.id, v).unwrap();
    }

    // View chronologique : ManualThenCreated croissant
    let mut vue = View::new("Chronologique", ViewType::Table);
    vue.sorts
        .push(Sort::manual_then_creation(date_id, Order::Ascending));
    let vue = add_view(&db_store, db.id, vue).unwrap();

    let resultats = requete(&db_store, db.id, vue.id).unwrap();
    assert_eq!(resultats.len(), 5);

    // Les 3 premières doivent être les notes anciennes dans l'order chronologique
    let dates: Vec<Option<&PropertyValue>> =
        resultats.iter().map(|e| e.values.get(&date_id)).collect();

    assert_eq!(
        dates[0],
        Some(&PropertyValue::Date("2019-03-22".to_string()))
    );
    assert_eq!(
        dates[1],
        Some(&PropertyValue::Date("2020-11-30".to_string()))
    );
    assert_eq!(
        dates[2],
        Some(&PropertyValue::Date("2021-08-14".to_string()))
    );
    // Les 2 news arrivent après (created_at récent > toutes les dates manuelles)
    assert!(
        dates[3].is_none() || dates[3] == Some(&PropertyValue::Empty) || {
            // pas de date manuelle donc tri par created_at
            resultats[3].created_at > "2021".to_string()
        }
    );
}
