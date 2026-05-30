use chaqaq::application::database_use_cases::{
    column_aggregate, add_entry, add_view, create_database, evaluate_rollups,
    list_databases, update_entry, get_database, requete, grouped_query,
    delete_entry,
};
use chaqaq::domain::database::{
    Agregat, ConditionFiltre, Filtre, Ordre, Propriete, ProprieteType, Tri, TypeVue,
    ValeurPropriete, Vue,
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

fn entree_nombre(prop_id: Uuid, n: f64) -> HashMap<Uuid, ValeurPropriete> {
    let mut map = HashMap::new();
    map.insert(prop_id, ValeurPropriete::Nombre(n));
    map
}

#[test]
fn test_creer_et_get_database() {
    let store = store_temp();
    let props = vec![Propriete::nouvelle("Nom", ProprieteType::Titre)];
    let db = create_database(&store, title("Projets"), props).unwrap();
    let chargee = get_database(&store, db.id).unwrap();
    assert_eq!(chargee.id, db.id);
    assert_eq!(chargee.proprietes.len(), 1);
}

#[test]
fn test_add_entry_persiste() {
    let store = store_temp();
    let prop = Propriete::nouvelle("Score", ProprieteType::Nombre);
    let prop_id = prop.id;
    let db = create_database(&store, title("Scores"), vec![prop]).unwrap();

    add_entry(&store, db.id, entree_nombre(prop_id, 10.0)).unwrap();
    add_entry(&store, db.id, entree_nombre(prop_id, 20.0)).unwrap();

    let chargee = get_database(&store, db.id).unwrap();
    assert_eq!(chargee.entrees.len(), 2);
}

#[test]
fn test_filtrer_entrees_par_valeur() {
    let store = store_temp();
    let prop = Propriete::nouvelle("Statut", ProprieteType::Texte);
    let prop_id = prop.id;
    let db = create_database(&store, title("Tâches"), vec![prop]).unwrap();

    let mut v1 = HashMap::new();
    v1.insert(prop_id, ValeurPropriete::Texte("En cours".to_string()));
    let mut v2 = HashMap::new();
    v2.insert(prop_id, ValeurPropriete::Texte("Terminé".to_string()));
    add_entry(&store, db.id, v1).unwrap();
    add_entry(&store, db.id, v2).unwrap();

    // ajoute une vue avec filtre
    let mut vue = Vue::nouvelle("En cours seulement", TypeVue::Tableau);
    vue.filtres.push(Filtre {
        property_id: prop_id,
        condition: ConditionFiltre::Contient("cours".to_string()),
    });
    let vue = add_view(&store, db.id, vue).unwrap();

    let resultats = requete(&store, db.id, vue.id).unwrap();
    assert_eq!(resultats.len(), 1);
}

#[test]
fn test_trier_entrees_par_nombre() {
    let store = store_temp();
    let prop = Propriete::nouvelle("Priorité", ProprieteType::Nombre);
    let prop_id = prop.id;
    let db = create_database(&store, title("Items"), vec![prop]).unwrap();

    add_entry(&store, db.id, entree_nombre(prop_id, 3.0)).unwrap();
    add_entry(&store, db.id, entree_nombre(prop_id, 1.0)).unwrap();
    add_entry(&store, db.id, entree_nombre(prop_id, 2.0)).unwrap();

    let mut vue = Vue::nouvelle("Par priorité", TypeVue::Tableau);
    vue.tris.push(Tri::par_propriete(prop_id, Ordre::Croissant));
    let vue = add_view(&store, db.id, vue).unwrap();

    let resultats = requete(&store, db.id, vue.id).unwrap();
    let valeurs: Vec<f64> = resultats
        .iter()
        .map(|e| match e.valeurs.get(&prop_id).unwrap() {
            ValeurPropriete::Nombre(n) => *n,
            _ => panic!("valeur inattendue"),
        })
        .collect();
    assert_eq!(valeurs, vec![1.0, 2.0, 3.0]);
}

#[test]
fn test_modifier_et_delete_entry() {
    let store = store_temp();
    let prop = Propriete::nouvelle("Note", ProprieteType::Nombre);
    let prop_id = prop.id;
    let db = create_database(&store, title("Notes"), vec![prop]).unwrap();

    let entree = add_entry(&store, db.id, entree_nombre(prop_id, 5.0)).unwrap();

    update_entry(&store, db.id, entree.id, entree_nombre(prop_id, 10.0)).unwrap();
    let db_modifiee = get_database(&store, db.id).unwrap();
    assert_eq!(
        db_modifiee.entrees[0].valeurs[&prop_id],
        ValeurPropriete::Nombre(10.0)
    );

    delete_entry(&store, db.id, entree.id).unwrap();
    let db_finale = get_database(&store, db.id).unwrap();
    assert!(db_finale.entrees.is_empty());
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
fn test_rollup_compte_entrees_liees() {
    let store = store_temp();

    // Database Tâches
    let prop_title = Propriete::nouvelle("Titre", ProprieteType::Titre);
    let db_taches = create_database(&store, title("Tâches"), vec![prop_title]).unwrap();

    // Ajoute 2 tâches
    let mut v1 = HashMap::new();
    v1.insert(
        db_taches.proprietes[0].id,
        ValeurPropriete::Titre(title("T1")),
    );
    let t1 = add_entry(&store, db_taches.id, v1).unwrap();

    let mut v2 = HashMap::new();
    v2.insert(
        db_taches.proprietes[0].id,
        ValeurPropriete::Titre(title("T2")),
    );
    let t2 = add_entry(&store, db_taches.id, v2).unwrap();

    // Database Projets avec Relation → Tâches et Rollup (Compter)
    let prop_rel = Propriete::nouvelle(
        "Tâches liées",
        ProprieteType::Relation {
            db_id: db_taches.id,
        },
    );
    let prop_nb = Propriete::nouvelle(
        "Nb tâches",
        ProprieteType::Rollup {
            relation_prop_id: prop_rel.id,
            cible_prop_id: db_taches.proprietes[0].id,
            agregat: Agregat::Compter,
        },
    );
    let nb_id = prop_nb.id;
    let rel_id = prop_rel.id;
    let db_projets = create_database(&store, title("Projets"), vec![prop_rel, prop_nb]).unwrap();

    // Ajoute un projet lié aux 2 tâches
    let mut vp = HashMap::new();
    vp.insert(rel_id, ValeurPropriete::Relation(vec![t1.id, t2.id]));
    let entree = add_entry(&store, db_projets.id, vp).unwrap();

    // Évalue les rollups
    let db = get_database(&store, db_projets.id).unwrap();
    let enrichies = evaluate_rollups(&store, &db, vec![entree]).unwrap();

    assert_eq!(enrichies[0].valeurs[&nb_id], ValeurPropriete::Nombre(2.0));
}

#[test]
fn test_column_aggregate_somme() {
    let store = store_temp();
    let prop = Propriete::nouvelle("Score", ProprieteType::Nombre);
    let prop_id = prop.id;
    let db = create_database(&store, title("Scores"), vec![prop]).unwrap();

    add_entry(&store, db.id, entree_nombre(prop_id, 10.0)).unwrap();
    add_entry(&store, db.id, entree_nombre(prop_id, 20.0)).unwrap();
    add_entry(&store, db.id, entree_nombre(prop_id, 30.0)).unwrap();

    let total = column_aggregate(&store, db.id, prop_id, Agregat::Somme).unwrap();
    assert_eq!(total, ValeurPropriete::Nombre(60.0));
}

#[test]
fn test_column_aggregate_moyenne() {
    let store = store_temp();
    let prop = Propriete::nouvelle("Note", ProprieteType::Nombre);
    let prop_id = prop.id;
    let db = create_database(&store, title("Notes"), vec![prop]).unwrap();

    add_entry(&store, db.id, entree_nombre(prop_id, 8.0)).unwrap();
    add_entry(&store, db.id, entree_nombre(prop_id, 12.0)).unwrap();

    let moy = column_aggregate(&store, db.id, prop_id, Agregat::Moyenne).unwrap();
    assert_eq!(moy, ValeurPropriete::Nombre(10.0));
}

// ── Groupement ───────────────────────────────────────────────────────────────

#[test]
fn test_grouped_query_par_selection() {
    let store = store_temp();
    let prop = Propriete::nouvelle(
        "Statut",
        ProprieteType::Selection(vec!["En cours".into(), "Terminé".into()]),
    );
    let prop_id = prop.id;
    let db = create_database(&store, title("Tâches"), vec![prop]).unwrap();
    let view_id = db.vues[0].id;

    let statuts = ["En cours", "Terminé", "En cours", "En cours"];
    for s in statuts {
        let mut v = HashMap::new();
        v.insert(prop_id, ValeurPropriete::Selection(Some(s.to_string())));
        add_entry(&store, db.id, v).unwrap();
    }

    let groupes = grouped_query(&store, db.id, view_id, prop_id).unwrap();
    assert_eq!(groupes.len(), 2);

    let en_cours = groupes
        .iter()
        .find(|g| g.valeur == ValeurPropriete::Selection(Some("En cours".to_string())))
        .unwrap();
    assert_eq!(en_cours.entrees.len(), 3);
}

#[test]
fn test_grouped_query_vide_en_dernier() {
    let store = store_temp();
    let prop = Propriete::nouvelle("Statut", ProprieteType::Texte);
    let prop_id = prop.id;
    let db = create_database(&store, title("Items"), vec![prop]).unwrap();
    let view_id = db.vues[0].id;

    // une entrée avec valeur, une sans
    let mut v1 = HashMap::new();
    v1.insert(prop_id, ValeurPropriete::Texte("Actif".to_string()));
    add_entry(&store, db.id, v1).unwrap();
    add_entry(&store, db.id, HashMap::new()).unwrap(); // Vide

    let groupes = grouped_query(&store, db.id, view_id, prop_id).unwrap();
    assert_eq!(groupes.len(), 2);
    // Vide trié en dernier
    assert_eq!(groupes.last().unwrap().valeur, ValeurPropriete::Vide);
}

// ── SourceTri : date auto, manuelle, hybride ─────────────────────────────────

#[test]
fn test_tri_par_creation_auto() {
    let store = store_temp();
    let db = create_database(&store, title("Journal"), vec![]).unwrap();
    // 3 entrées créées avec des cree_le manuellement espacés pour le test
    let mut e1 = chaqaq::domain::database::Entree::nouvelle(HashMap::new());
    e1.cree_le = "2023-01-01T00:00:00+00:00".to_string();
    let mut e2 = chaqaq::domain::database::Entree::nouvelle(HashMap::new());
    e2.cree_le = "2023-06-15T00:00:00+00:00".to_string();
    let mut e3 = chaqaq::domain::database::Entree::nouvelle(HashMap::new());
    e3.cree_le = "2022-12-01T00:00:00+00:00".to_string();

    // Persiste via save direct
    use chaqaq::application::database_repository::DatabaseRepository;
    let mut db = get_database(&store, db.id).unwrap();
    db.entrees = vec![e1.clone(), e2.clone(), e3.clone()];
    store.save(&db).unwrap();

    let mut vue = Vue::nouvelle("Chronologique", TypeVue::Tableau);
    vue.tris.push(Tri::par_creation(Ordre::Croissant));
    let vue = add_view(&store, db.id, vue).unwrap();

    let resultats = requete(&store, db.id, vue.id).unwrap();
    assert_eq!(resultats[0].cree_le, "2022-12-01T00:00:00+00:00");
    assert_eq!(resultats[1].cree_le, "2023-01-01T00:00:00+00:00");
    assert_eq!(resultats[2].cree_le, "2023-06-15T00:00:00+00:00");
}

#[test]
fn test_tri_manuelle_puis_creation_cas_journal() {
    let store = store_temp();
    let prop_date = Propriete::nouvelle("Date", ProprieteType::Date);
    let date_id = prop_date.id;
    let db = create_database(&store, title("Journal"), vec![prop_date]).unwrap();

    // Note ancienne : date manuelle renseignée, cree_le récent (import)
    let mut v_ancienne = HashMap::new();
    v_ancienne.insert(date_id, ValeurPropriete::Date("2020-05-10".to_string()));
    let mut e_ancienne = chaqaq::domain::database::Entree::nouvelle(v_ancienne);
    e_ancienne.cree_le = "2024-01-01T00:00:00+00:00".to_string(); // importée récemment

    // Note nouvelle : pas de date manuelle, cree_le = date réelle d'écriture
    let mut e_nouvelle = chaqaq::domain::database::Entree::nouvelle(HashMap::new());
    e_nouvelle.cree_le = "2024-06-01T00:00:00+00:00".to_string();

    use chaqaq::application::database_repository::DatabaseRepository;
    let mut db = get_database(&store, db.id).unwrap();
    db.entrees = vec![e_nouvelle.clone(), e_ancienne.clone()]; // order inversé intentionnel
    store.save(&db).unwrap();

    // Vue avec tri ManuellePuisCreation croissant
    let mut vue = Vue::nouvelle("Chronologique", TypeVue::Tableau);
    vue.tris
        .push(Tri::manuelle_puis_creation(date_id, Ordre::Croissant));
    let vue = add_view(&store, db.id, vue).unwrap();

    let resultats = requete(&store, db.id, vue.id).unwrap();
    // L'ancienne note (date manuelle 2020) doit passer AVANT la nouvelle (cree_le 2024)
    let date_premiere = resultats[0].valeurs.get(&date_id);
    assert_eq!(
        date_premiere,
        Some(&ValeurPropriete::Date("2020-05-10".to_string()))
    );
}
