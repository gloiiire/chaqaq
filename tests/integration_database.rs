use std::collections::HashMap;
use uuid::Uuid;
use chaqaq::application::database_use_cases::{
    ajouter_entree, ajouter_vue, creer_database, lister_databases, obtenir_database, requete,
    supprimer_entree, modifier_entree,
};
use chaqaq::domain::database::{
    ConditionFiltre, Filtre, Ordre, ProprieteType, Propriete,
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
