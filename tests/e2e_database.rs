use std::collections::HashMap;
use uuid::Uuid;
use chaqaq::application::database_use_cases::{
    ajouter_entree, ajouter_propriete, ajouter_vue, creer_database,
    obtenir_database, requete,
};
use chaqaq::application::repository::DocumentRepository;
use chaqaq::application::use_cases::creer_document;
use chaqaq::domain::database::{
    ConditionFiltre, Filtre, Ordre, ProprieteType, Propriete,
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
