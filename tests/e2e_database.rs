use std::collections::HashMap;
use uuid::Uuid;
use chaqaq::application::database_use_cases::{
    agregat_colonne, ajouter_entree, ajouter_propriete, ajouter_vue,
    creer_database, evaluer_rollups, obtenir_database, requete,
    requete_groupee,
};
use chaqaq::application::repository::DocumentRepository;
use chaqaq::application::use_cases::creer_document;
use chaqaq::domain::database::{
    Agregat, ConditionFiltre, Filtre, Ordre, ProprieteType, Propriete,
    Tri, TypeVue, ValeurPropriete, Vue,
};
use chaqaq::domain::document::{BlockContent, InlineText};
use chaqaq::infrastructure::database_store::DatabaseStore;
use chaqaq::infrastructure::json_store::JsonStore;

fn titre(s: &str) -> Vec<InlineText> {
    vec![InlineText { content: s.to_string(), styles: vec![] }]
}

fn store_temp() -> (JsonStore, DatabaseStore) {
    let id = Uuid::new_v4();
    let doc_dir = std::env::temp_dir().join(format!("chaqaq_e2e_docs_{id}"));
    let db_dir  = std::env::temp_dir().join(format!("chaqaq_e2e_dbs_{id}"));
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
    let prop_nom     = Propriete::nouvelle("Nom",     ProprieteType::Titre);
    let prop_score   = Propriete::nouvelle("Score",   ProprieteType::Nombre);
    let nom_id   = prop_nom.id;
    let score_id = prop_score.id;

    let db = creer_database(&db_store, titre("Classement"), vec![prop_nom, prop_score]).unwrap();

    // ajoute des entrées
    let mut v1 = HashMap::new();
    v1.insert(nom_id,   ValeurPropriete::Titre(titre("Alice")));
    v1.insert(score_id, ValeurPropriete::Nombre(95.0));

    let mut v2 = HashMap::new();
    v2.insert(nom_id,   ValeurPropriete::Titre(titre("Bob")));
    v2.insert(score_id, ValeurPropriete::Nombre(82.0));

    let mut v3 = HashMap::new();
    v3.insert(nom_id,   ValeurPropriete::Titre(titre("Charlie")));
    v3.insert(score_id, ValeurPropriete::Nombre(88.0));

    ajouter_entree(&db_store, db.id, v1).unwrap();
    ajouter_entree(&db_store, db.id, v2).unwrap();
    ajouter_entree(&db_store, db.id, v3).unwrap();

    // vue triée par score décroissant
    let mut vue = Vue::nouvelle("Top scores", TypeVue::Tableau);
    vue.tris.push(Tri { propriete_id: score_id, ordre: Ordre::Decroissant });
    let vue = ajouter_vue(&db_store, db.id, vue).unwrap();

    let resultats = requete(&db_store, db.id, vue.id).unwrap();
    assert_eq!(resultats.len(), 3);
    assert_eq!(
        resultats[0].valeurs[&score_id],
        ValeurPropriete::Nombre(95.0)
    );
}

#[test]
fn test_database_liee_a_document() {
    let (doc_store, db_store) = store_temp();

    let db = creer_database(&db_store, titre("Tâches"), vec![]).unwrap();

    // document qui référence la database via un bloc
    let mut doc = creer_document(&doc_store, "Mon projet").unwrap();
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

    let prop_statut  = Propriete::nouvelle("Statut", ProprieteType::Texte);
    let prop_priorite = Propriete::nouvelle("Priorité", ProprieteType::Nombre);
    let statut_id   = prop_statut.id;
    let priorite_id = prop_priorite.id;

    let db = creer_database(&db_store, titre("Backlog"), vec![prop_statut, prop_priorite]).unwrap();

    let entrees = vec![
        ("En cours", 3.0),
        ("Terminé",  1.0),
        ("En cours", 1.0),
        ("Terminé",  2.0),
    ];
    for (s, p) in entrees {
        let mut v = HashMap::new();
        v.insert(statut_id,   ValeurPropriete::Texte(s.to_string()));
        v.insert(priorite_id, ValeurPropriete::Nombre(p));
        ajouter_entree(&db_store, db.id, v).unwrap();
    }

    let mut vue = Vue::nouvelle("En cours par priorité", TypeVue::Tableau);
    vue.filtres.push(Filtre {
        propriete_id: statut_id,
        condition: ConditionFiltre::Egal(ValeurPropriete::Texte("En cours".to_string())),
    });
    vue.tris.push(Tri { propriete_id: priorite_id, ordre: Ordre::Croissant });
    let vue = ajouter_vue(&db_store, db.id, vue).unwrap();

    let resultats = requete(&db_store, db.id, vue.id).unwrap();
    assert_eq!(resultats.len(), 2);
    assert_eq!(
        resultats[0].valeurs[&priorite_id],
        ValeurPropriete::Nombre(1.0)
    );
}

#[test]
fn test_ajouter_propriete_a_database_existante() {
    let (_doc_store, db_store) = store_temp();
    let db = creer_database(&db_store, titre("Notes"), vec![]).unwrap();
    assert_eq!(obtenir_database(&db_store, db.id).unwrap().proprietes.len(), 0);

    ajouter_propriete(&db_store, db.id, Propriete::nouvelle("Date", ProprieteType::Date)).unwrap();
    assert_eq!(obtenir_database(&db_store, db.id).unwrap().proprietes.len(), 1);
}

// ── E2E Relations & Rollups ──────────────────────────────────────────────────

#[test]
fn test_flux_rollup_entre_deux_databases() {
    let (_doc_store, db_store) = store_temp();

    // Sprints (database source des relations)
    let prop_points = Propriete::nouvelle("Points", ProprieteType::Nombre);
    let points_id = prop_points.id;
    let db_sprints = creer_database(&db_store, titre("Sprints"), vec![prop_points]).unwrap();

    let mut s1 = HashMap::new(); s1.insert(points_id, ValeurPropriete::Nombre(8.0));
    let mut s2 = HashMap::new(); s2.insert(points_id, ValeurPropriete::Nombre(13.0));
    let sprint1 = ajouter_entree(&db_store, db_sprints.id, s1).unwrap();
    let sprint2 = ajouter_entree(&db_store, db_sprints.id, s2).unwrap();

    // Projets avec Relation → Sprints + Rollup (Somme des points)
    let prop_rel = Propriete::nouvelle("Sprints", ProprieteType::Relation { db_id: db_sprints.id });
    let prop_total = Propriete::nouvelle(
        "Total points",
        ProprieteType::Rollup {
            relation_prop_id: prop_rel.id,
            cible_prop_id: points_id,
            agregat: Agregat::Somme,
        },
    );
    let total_id = prop_total.id;
    let rel_id = prop_rel.id;
    let db_projets = creer_database(&db_store, titre("Projets"), vec![prop_rel, prop_total]).unwrap();

    let mut vp = HashMap::new();
    vp.insert(rel_id, ValeurPropriete::Relation(vec![sprint1.id, sprint2.id]));
    let projet = ajouter_entree(&db_store, db_projets.id, vp).unwrap();

    let db = obtenir_database(&db_store, db_projets.id).unwrap();
    let enrichies = evaluer_rollups(&db_store, &db, vec![projet]).unwrap();

    assert_eq!(enrichies[0].valeurs[&total_id], ValeurPropriete::Nombre(21.0));
}

// ── E2E Kanban (groupement) ──────────────────────────────────────────────────

#[test]
fn test_flux_kanban_complet() {
    let (_doc_store, db_store) = store_temp();

    let prop_statut = Propriete::nouvelle(
        "Statut",
        ProprieteType::Selection(vec!["Todo".into(), "En cours".into(), "Terminé".into()]),
    );
    let statut_id = prop_statut.id;
    let db = creer_database(&db_store, titre("Backlog"), vec![prop_statut]).unwrap();

    // Vue Kanban groupée par statut
    let vue_kanban = Vue::nouvelle("Kanban", TypeVue::Kanban { grouper_par: statut_id });
    let vue_kanban = ajouter_vue(&db_store, db.id, vue_kanban).unwrap();

    let tickets = [
        ("Todo", 3),
        ("En cours", 2),
        ("Terminé", 1),
    ];
    for (statut, n) in tickets {
        for _ in 0..n {
            let mut v = HashMap::new();
            v.insert(statut_id, ValeurPropriete::Selection(Some(statut.to_string())));
            ajouter_entree(&db_store, db.id, v).unwrap();
        }
    }

    let groupes = requete_groupee(&db_store, db.id, vue_kanban.id, statut_id).unwrap();
    assert_eq!(groupes.len(), 3);
    let total: usize = groupes.iter().map(|g| g.entrees.len()).sum();
    assert_eq!(total, 6);
}

// ── E2E Agrégat colonne ──────────────────────────────────────────────────────

#[test]
fn test_agregat_min_max_colonne() {
    let (_doc_store, db_store) = store_temp();

    let prop = Propriete::nouvelle("Durée", ProprieteType::Nombre);
    let prop_id = prop.id;
    let db = creer_database(&db_store, titre("Tâches"), vec![prop]).unwrap();

    for n in [5.0, 1.0, 9.0, 3.0] {
        let mut v = HashMap::new();
        v.insert(prop_id, ValeurPropriete::Nombre(n));
        ajouter_entree(&db_store, db.id, v).unwrap();
    }

    let min = agregat_colonne(&db_store, db.id, prop_id, Agregat::Min).unwrap();
    let max = agregat_colonne(&db_store, db.id, prop_id, Agregat::Max).unwrap();

    assert_eq!(min, ValeurPropriete::Nombre(1.0));
    assert_eq!(max, ValeurPropriete::Nombre(9.0));
}
