use std::collections::HashMap;
use uuid::Uuid;
use chaqaq::application::database_use_cases::{
    agregat_colonne, ajouter_entree, ajouter_vue, creer_database,
    evaluer_rollups, lister_databases, obtenir_database, requete,
    requete_groupee, supprimer_entree, modifier_entree,
};
use chaqaq::domain::database::{
    Agregat, ConditionFiltre, Filtre, Ordre, ProprieteType, Propriete,
    Tri, TypeVue, ValeurPropriete, Vue,
};
use chaqaq::domain::document::InlineText;
use chaqaq::infrastructure::database_store::DatabaseStore;

fn store_temp() -> DatabaseStore {
    let dir = std::env::temp_dir().join(format!("chaqaq_db_integ_{}", Uuid::new_v4()));
    DatabaseStore::nouveau(dir).unwrap()
}

fn titre(s: &str) -> Vec<InlineText> {
    vec![InlineText { content: s.to_string(), styles: vec![] }]
}

fn entree_nombre(prop_id: Uuid, n: f64) -> HashMap<Uuid, ValeurPropriete> {
    let mut map = HashMap::new();
    map.insert(prop_id, ValeurPropriete::Nombre(n));
    map
}

#[test]
fn test_creer_et_obtenir_database() {
    let store = store_temp();
    let props = vec![Propriete::nouvelle("Nom", ProprieteType::Titre)];
    let db = creer_database(&store, titre("Projets"), props).unwrap();
    let chargee = obtenir_database(&store, db.id).unwrap();
    assert_eq!(chargee.id, db.id);
    assert_eq!(chargee.proprietes.len(), 1);
}

#[test]
fn test_ajouter_entree_persiste() {
    let store = store_temp();
    let prop = Propriete::nouvelle("Score", ProprieteType::Nombre);
    let prop_id = prop.id;
    let db = creer_database(&store, titre("Scores"), vec![prop]).unwrap();

    ajouter_entree(&store, db.id, entree_nombre(prop_id, 10.0)).unwrap();
    ajouter_entree(&store, db.id, entree_nombre(prop_id, 20.0)).unwrap();

    let chargee = obtenir_database(&store, db.id).unwrap();
    assert_eq!(chargee.entrees.len(), 2);
}

#[test]
fn test_filtrer_entrees_par_valeur() {
    let store = store_temp();
    let prop = Propriete::nouvelle("Statut", ProprieteType::Texte);
    let prop_id = prop.id;
    let db = creer_database(&store, titre("Tâches"), vec![prop]).unwrap();

    let mut v1 = HashMap::new();
    v1.insert(prop_id, ValeurPropriete::Texte("En cours".to_string()));
    let mut v2 = HashMap::new();
    v2.insert(prop_id, ValeurPropriete::Texte("Terminé".to_string()));
    ajouter_entree(&store, db.id, v1).unwrap();
    ajouter_entree(&store, db.id, v2).unwrap();

    // ajoute une vue avec filtre
    let mut vue = Vue::nouvelle("En cours seulement", TypeVue::Tableau);
    vue.filtres.push(Filtre {
        propriete_id: prop_id,
        condition: ConditionFiltre::Contient("cours".to_string()),
    });
    let vue = ajouter_vue(&store, db.id, vue).unwrap();

    let resultats = requete(&store, db.id, vue.id).unwrap();
    assert_eq!(resultats.len(), 1);
}

#[test]
fn test_trier_entrees_par_nombre() {
    let store = store_temp();
    let prop = Propriete::nouvelle("Priorité", ProprieteType::Nombre);
    let prop_id = prop.id;
    let db = creer_database(&store, titre("Items"), vec![prop]).unwrap();

    ajouter_entree(&store, db.id, entree_nombre(prop_id, 3.0)).unwrap();
    ajouter_entree(&store, db.id, entree_nombre(prop_id, 1.0)).unwrap();
    ajouter_entree(&store, db.id, entree_nombre(prop_id, 2.0)).unwrap();

    let mut vue = Vue::nouvelle("Par priorité", TypeVue::Tableau);
    vue.tris.push(Tri { propriete_id: prop_id, ordre: Ordre::Croissant });
    let vue = ajouter_vue(&store, db.id, vue).unwrap();

    let resultats = requete(&store, db.id, vue.id).unwrap();
    let valeurs: Vec<f64> = resultats.iter().map(|e| {
        match e.valeurs.get(&prop_id).unwrap() {
            ValeurPropriete::Nombre(n) => *n,
            _ => panic!("valeur inattendue"),
        }
    }).collect();
    assert_eq!(valeurs, vec![1.0, 2.0, 3.0]);
}

#[test]
fn test_modifier_et_supprimer_entree() {
    let store = store_temp();
    let prop = Propriete::nouvelle("Note", ProprieteType::Nombre);
    let prop_id = prop.id;
    let db = creer_database(&store, titre("Notes"), vec![prop]).unwrap();

    let entree = ajouter_entree(&store, db.id, entree_nombre(prop_id, 5.0)).unwrap();

    modifier_entree(&store, db.id, entree.id, entree_nombre(prop_id, 10.0)).unwrap();
    let db_modifiee = obtenir_database(&store, db.id).unwrap();
    assert_eq!(
        db_modifiee.entrees[0].valeurs[&prop_id],
        ValeurPropriete::Nombre(10.0)
    );

    supprimer_entree(&store, db.id, entree.id).unwrap();
    let db_finale = obtenir_database(&store, db.id).unwrap();
    assert!(db_finale.entrees.is_empty());
}

#[test]
fn test_lister_databases() {
    let store = store_temp();
    creer_database(&store, titre("DB1"), vec![]).unwrap();
    creer_database(&store, titre("DB2"), vec![]).unwrap();
    let metas = lister_databases(&store).unwrap();
    assert_eq!(metas.len(), 2);
}

// ── Relations & Rollups ──────────────────────────────────────────────────────

#[test]
fn test_rollup_compte_entrees_liees() {
    let store = store_temp();

    // Database Tâches
    let prop_titre = Propriete::nouvelle("Titre", ProprieteType::Titre);
    let db_taches = creer_database(&store, titre("Tâches"), vec![prop_titre]).unwrap();

    // Ajoute 2 tâches
    let mut v1 = HashMap::new();
    v1.insert(db_taches.proprietes[0].id, ValeurPropriete::Titre(titre("T1")));
    let t1 = ajouter_entree(&store, db_taches.id, v1).unwrap();

    let mut v2 = HashMap::new();
    v2.insert(db_taches.proprietes[0].id, ValeurPropriete::Titre(titre("T2")));
    let t2 = ajouter_entree(&store, db_taches.id, v2).unwrap();

    // Database Projets avec Relation → Tâches et Rollup (Compter)
    let prop_rel = Propriete::nouvelle("Tâches liées", ProprieteType::Relation { db_id: db_taches.id });
    let prop_nb  = Propriete::nouvelle(
        "Nb tâches",
        ProprieteType::Rollup {
            relation_prop_id: prop_rel.id,
            cible_prop_id: db_taches.proprietes[0].id,
            agregat: Agregat::Compter,
        },
    );
    let nb_id = prop_nb.id;
    let rel_id = prop_rel.id;
    let db_projets = creer_database(&store, titre("Projets"), vec![prop_rel, prop_nb]).unwrap();

    // Ajoute un projet lié aux 2 tâches
    let mut vp = HashMap::new();
    vp.insert(rel_id, ValeurPropriete::Relation(vec![t1.id, t2.id]));
    let entree = ajouter_entree(&store, db_projets.id, vp).unwrap();

    // Évalue les rollups
    let db = obtenir_database(&store, db_projets.id).unwrap();
    let enrichies = evaluer_rollups(&store, &db, vec![entree]).unwrap();

    assert_eq!(enrichies[0].valeurs[&nb_id], ValeurPropriete::Nombre(2.0));
}

#[test]
fn test_agregat_colonne_somme() {
    let store = store_temp();
    let prop = Propriete::nouvelle("Score", ProprieteType::Nombre);
    let prop_id = prop.id;
    let db = creer_database(&store, titre("Scores"), vec![prop]).unwrap();

    ajouter_entree(&store, db.id, entree_nombre(prop_id, 10.0)).unwrap();
    ajouter_entree(&store, db.id, entree_nombre(prop_id, 20.0)).unwrap();
    ajouter_entree(&store, db.id, entree_nombre(prop_id, 30.0)).unwrap();

    let total = agregat_colonne(&store, db.id, prop_id, Agregat::Somme).unwrap();
    assert_eq!(total, ValeurPropriete::Nombre(60.0));
}

#[test]
fn test_agregat_colonne_moyenne() {
    let store = store_temp();
    let prop = Propriete::nouvelle("Note", ProprieteType::Nombre);
    let prop_id = prop.id;
    let db = creer_database(&store, titre("Notes"), vec![prop]).unwrap();

    ajouter_entree(&store, db.id, entree_nombre(prop_id, 8.0)).unwrap();
    ajouter_entree(&store, db.id, entree_nombre(prop_id, 12.0)).unwrap();

    let moy = agregat_colonne(&store, db.id, prop_id, Agregat::Moyenne).unwrap();
    assert_eq!(moy, ValeurPropriete::Nombre(10.0));
}

// ── Groupement ───────────────────────────────────────────────────────────────

#[test]
fn test_requete_groupee_par_selection() {
    let store = store_temp();
    let prop = Propriete::nouvelle(
        "Statut",
        ProprieteType::Selection(vec!["En cours".into(), "Terminé".into()]),
    );
    let prop_id = prop.id;
    let db = creer_database(&store, titre("Tâches"), vec![prop]).unwrap();
    let vue_id = db.vues[0].id;

    let statuts = ["En cours", "Terminé", "En cours", "En cours"];
    for s in statuts {
        let mut v = HashMap::new();
        v.insert(prop_id, ValeurPropriete::Selection(Some(s.to_string())));
        ajouter_entree(&store, db.id, v).unwrap();
    }

    let groupes = requete_groupee(&store, db.id, vue_id, prop_id).unwrap();
    assert_eq!(groupes.len(), 2);

    let en_cours = groupes.iter().find(|g| g.valeur == ValeurPropriete::Selection(Some("En cours".to_string()))).unwrap();
    assert_eq!(en_cours.entrees.len(), 3);
}

#[test]
fn test_requete_groupee_vide_en_dernier() {
    let store = store_temp();
    let prop = Propriete::nouvelle("Statut", ProprieteType::Texte);
    let prop_id = prop.id;
    let db = creer_database(&store, titre("Items"), vec![prop]).unwrap();
    let vue_id = db.vues[0].id;

    // une entrée avec valeur, une sans
    let mut v1 = HashMap::new();
    v1.insert(prop_id, ValeurPropriete::Texte("Actif".to_string()));
    ajouter_entree(&store, db.id, v1).unwrap();
    ajouter_entree(&store, db.id, HashMap::new()).unwrap(); // Vide

    let groupes = requete_groupee(&store, db.id, vue_id, prop_id).unwrap();
    assert_eq!(groupes.len(), 2);
    // Vide trié en dernier
    assert_eq!(groupes.last().unwrap().valeur, ValeurPropriete::Vide);
}
