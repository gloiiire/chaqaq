use std::collections::HashMap;
use std::cmp::Ordering;
use uuid::Uuid;
use crate::application::database_repository::DatabaseRepository;
use crate::application::error::ChaqaqError;
use crate::domain::database::{
    ConditionFiltre, Database, DatabaseMeta, Entree, Filtre, Ordre,
    Propriete, ValeurPropriete, Vue,
};
use crate::domain::document::InlineText;

pub fn creer_database(
    repo: &dyn DatabaseRepository,
    titre: Vec<InlineText>,
    proprietes: Vec<Propriete>,
) -> Result<Database, ChaqaqError> {
    let db = Database::nouvelle(titre, proprietes);
    repo.save(&db)?;
    Ok(db)
}

pub fn obtenir_database(
    repo: &dyn DatabaseRepository,
    id: Uuid,
) -> Result<Database, ChaqaqError> {
    repo.load(id)
}

pub fn lister_databases(
    repo: &dyn DatabaseRepository,
) -> Result<Vec<DatabaseMeta>, ChaqaqError> {
    repo.list_meta()
}

pub fn ajouter_entree(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    valeurs: HashMap<Uuid, ValeurPropriete>,
) -> Result<Entree, ChaqaqError> {
    let mut db = repo.load(db_id)?;
    let entree = Entree::nouvelle(valeurs);
    db.entrees.push(entree.clone());
    repo.save(&db)?;
    Ok(entree)
}

pub fn modifier_entree(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    entree_id: Uuid,
    valeurs: HashMap<Uuid, ValeurPropriete>,
) -> Result<(), ChaqaqError> {
    let mut db = repo.load(db_id)?;
    let entree = db.entrees
        .iter_mut()
        .find(|e| e.id == entree_id)
        .ok_or(ChaqaqError::NonTrouve(entree_id))?;
    entree.valeurs = valeurs;
    repo.save(&db)
}

pub fn supprimer_entree(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    entree_id: Uuid,
) -> Result<(), ChaqaqError> {
    let mut db = repo.load(db_id)?;
    let avant = db.entrees.len();
    db.entrees.retain(|e| e.id != entree_id);
    if db.entrees.len() == avant {
        return Err(ChaqaqError::NonTrouve(entree_id));
    }
    repo.save(&db)
}

pub fn ajouter_propriete(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    propriete: Propriete,
) -> Result<(), ChaqaqError> {
    let mut db = repo.load(db_id)?;
    db.proprietes.push(propriete);
    repo.save(&db)
}

pub fn ajouter_vue(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    vue: Vue,
) -> Result<Vue, ChaqaqError> {
    let mut db = repo.load(db_id)?;
    db.vues.push(vue.clone());
    repo.save(&db)?;
    Ok(vue)
}

pub fn requete(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    vue_id: Uuid,
) -> Result<Vec<Entree>, ChaqaqError> {
    let db = repo.load(db_id)?;
    let vue = db.vues
        .iter()
        .find(|v| v.id == vue_id)
        .ok_or(ChaqaqError::NonTrouve(vue_id))?;

    let mut entrees: Vec<Entree> = db.entrees
        .iter()
        .filter(|e| vue.filtres.iter().all(|f| appliquer_filtre(e, f)))
        .cloned()
        .collect();

    for tri in vue.tris.iter().rev() {
        entrees.sort_by(|a, b| {
            let va = a.valeurs.get(&tri.propriete_id).unwrap_or(&ValeurPropriete::Vide);
            let vb = b.valeurs.get(&tri.propriete_id).unwrap_or(&ValeurPropriete::Vide);
            let ord = comparer_valeurs(va, vb);
            if tri.ordre == Ordre::Decroissant { ord.reverse() } else { ord }
        });
    }

    Ok(entrees)
}

// ── Helpers internes ─────────────────────────────────────────────────────────

fn appliquer_filtre(entree: &Entree, filtre: &Filtre) -> bool {
    let valeur = entree.valeurs.get(&filtre.propriete_id).unwrap_or(&ValeurPropriete::Vide);
    match &filtre.condition {
        ConditionFiltre::EstVide  => matches!(valeur, ValeurPropriete::Vide),
        ConditionFiltre::EstPlein => !matches!(valeur, ValeurPropriete::Vide),
        ConditionFiltre::Egal(v)  => valeur == v,
        ConditionFiltre::Contient(s) => match valeur {
            ValeurPropriete::Texte(t) => t.contains(s.as_str()),
            ValeurPropriete::Url(u)   => u.contains(s.as_str()),
            ValeurPropriete::Titre(inlines) => {
                inlines.iter().any(|i| i.content.contains(s.as_str()))
            }
            _ => false,
        },
    }
}

fn comparer_valeurs(a: &ValeurPropriete, b: &ValeurPropriete) -> Ordering {
    match (a, b) {
        (ValeurPropriete::Nombre(x), ValeurPropriete::Nombre(y)) => {
            x.partial_cmp(y).unwrap_or(Ordering::Equal)
        }
        (ValeurPropriete::Texte(x),  ValeurPropriete::Texte(y))  => x.cmp(y),
        (ValeurPropriete::Date(x),   ValeurPropriete::Date(y))   => x.cmp(y),
        (ValeurPropriete::Case(x),   ValeurPropriete::Case(y))   => x.cmp(y),
        (ValeurPropriete::Vide,      ValeurPropriete::Vide)      => Ordering::Equal,
        (ValeurPropriete::Vide,      _)                          => Ordering::Greater,
        (_,                          ValeurPropriete::Vide)      => Ordering::Less,
        _ => Ordering::Equal,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entree_avec_nombre(prop_id: Uuid, n: f64) -> Entree {
        let mut map = HashMap::new();
        map.insert(prop_id, ValeurPropriete::Nombre(n));
        Entree::nouvelle(map)
    }

    fn entree_avec_texte(prop_id: Uuid, s: &str) -> Entree {
        let mut map = HashMap::new();
        map.insert(prop_id, ValeurPropriete::Texte(s.to_string()));
        Entree::nouvelle(map)
    }

    #[test]
    fn test_filtre_est_vide() {
        let prop_id = Uuid::new_v4();
        let entree = Entree::nouvelle(HashMap::new());
        let filtre = Filtre { propriete_id: prop_id, condition: ConditionFiltre::EstVide };
        assert!(appliquer_filtre(&entree, &filtre));
    }

    #[test]
    fn test_filtre_est_plein() {
        let prop_id = Uuid::new_v4();
        let entree = entree_avec_texte(prop_id, "valeur");
        let filtre = Filtre { propriete_id: prop_id, condition: ConditionFiltre::EstPlein };
        assert!(appliquer_filtre(&entree, &filtre));
    }

    #[test]
    fn test_filtre_contient() {
        let prop_id = Uuid::new_v4();
        let entree = entree_avec_texte(prop_id, "Bonjour monde");
        let filtre = Filtre {
            propriete_id: prop_id,
            condition: ConditionFiltre::Contient("monde".to_string()),
        };
        assert!(appliquer_filtre(&entree, &filtre));
    }

    #[test]
    fn test_filtre_egal_nombre() {
        let prop_id = Uuid::new_v4();
        let entree = entree_avec_nombre(prop_id, 42.0);
        let filtre = Filtre {
            propriete_id: prop_id,
            condition: ConditionFiltre::Egal(ValeurPropriete::Nombre(42.0)),
        };
        assert!(appliquer_filtre(&entree, &filtre));
    }

    #[test]
    fn test_comparer_nombres() {
        let a = ValeurPropriete::Nombre(1.0);
        let b = ValeurPropriete::Nombre(2.0);
        assert_eq!(comparer_valeurs(&a, &b), Ordering::Less);
    }

    #[test]
    fn test_vide_en_dernier() {
        let a = ValeurPropriete::Vide;
        let b = ValeurPropriete::Nombre(0.0);
        assert_eq!(comparer_valeurs(&a, &b), Ordering::Greater);
    }
}
