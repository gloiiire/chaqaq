use std::collections::HashMap;
use std::cmp::Ordering;
use uuid::Uuid;
use crate::application::database_repository::DatabaseRepository;
use crate::application::error::ChaqaqError;
use crate::domain::database::{
    Agregat, ConditionFiltre, Database, DatabaseMeta, Entree, Filtre, Groupe,
    Ordre, Propriete, ProprieteType, SourceTri, ValeurPropriete, Vue,
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

pub fn supprimer_database(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
) -> Result<(), ChaqaqError> {
    repo.delete(db_id)
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
            let ord = match &tri.source {
                SourceTri::Propriete => {
                    let va = a.valeurs.get(&tri.propriete_id).unwrap_or(&ValeurPropriete::Vide);
                    let vb = b.valeurs.get(&tri.propriete_id).unwrap_or(&ValeurPropriete::Vide);
                    comparer_valeurs(va, vb)
                }
                SourceTri::Creation => a.cree_le.cmp(&b.cree_le),
                SourceTri::ManuellePuisCreation => {
                    let va = a.valeurs.get(&tri.propriete_id).unwrap_or(&ValeurPropriete::Vide);
                    let vb = b.valeurs.get(&tri.propriete_id).unwrap_or(&ValeurPropriete::Vide);
                    date_effective(va, &a.cree_le).cmp(date_effective(vb, &b.cree_le))
                }
            };
            if tri.ordre == Ordre::Decroissant { ord.reverse() } else { ord }
        });
    }

    Ok(entrees)
}

// ── Recherche ────────────────────────────────────────────────────────────────

/// Recherche insensible à la casse dans toutes les valeurs textuelles des entrées.
pub fn rechercher_entrees(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    query: &str,
) -> Result<Vec<Entree>, ChaqaqError> {
    let db = repo.load(db_id)?;
    let q = query.to_lowercase();
    Ok(db.entrees.into_iter()
        .filter(|e| entree_correspond(e, &q))
        .collect())
}

fn entree_correspond(entree: &Entree, query: &str) -> bool {
    entree.valeurs.values().any(|v| valeur_contient(v, query))
}

fn valeur_contient(v: &ValeurPropriete, query: &str) -> bool {
    match v {
        ValeurPropriete::Texte(s)              => s.to_lowercase().contains(query),
        ValeurPropriete::Url(s)                => s.to_lowercase().contains(query),
        ValeurPropriete::Selection(Some(s))    => s.to_lowercase().contains(query),
        ValeurPropriete::SelectionMultiple(vs) => vs.iter().any(|s| s.to_lowercase().contains(query)),
        ValeurPropriete::Titre(inlines)        =>
            inlines.iter().any(|i| i.content.to_lowercase().contains(query)),
        _ => false,
    }
}

// ── Relations, Rollups, Agrégats, Groupement ─────────────────────────────────

/// Enrichit les entrées avec les valeurs calculées des colonnes Rollup.
/// Les valeurs rollup ne sont pas persistées — calculées à la lecture.
pub fn evaluer_rollups(
    repo: &dyn DatabaseRepository,
    db: &Database,
    mut entrees: Vec<Entree>,
) -> Result<Vec<Entree>, ChaqaqError> {
    let rollups: Vec<(Uuid, Uuid, Uuid, Agregat)> = db.proprietes.iter()
        .filter_map(|p| match &p.type_ {
            ProprieteType::Rollup { relation_prop_id, cible_prop_id, agregat } =>
                Some((p.id, *relation_prop_id, *cible_prop_id, agregat.clone())),
            _ => None,
        })
        .collect();

    if rollups.is_empty() {
        return Ok(entrees);
    }

    for (rollup_id, relation_prop_id, cible_prop_id, agregat) in rollups {
        let db_liee_id = db.proprietes.iter()
            .find(|p| p.id == relation_prop_id)
            .and_then(|p| match &p.type_ {
                ProprieteType::Relation { db_id } => Some(*db_id),
                _ => None,
            })
            .ok_or(ChaqaqError::NonTrouve(relation_prop_id))?;

        let db_liee = repo.load(db_liee_id)?;

        for entree in &mut entrees {
            let ids_lies = match entree.valeurs.get(&relation_prop_id) {
                Some(ValeurPropriete::Relation(ids)) => ids.clone(),
                _ => vec![],
            };
            let liees: Vec<&Entree> = db_liee.entrees.iter()
                .filter(|e| ids_lies.contains(&e.id))
                .collect();
            entree.valeurs.insert(rollup_id, calculer_agregat(&liees, cible_prop_id, &agregat));
        }
    }

    Ok(entrees)
}

/// Requête filtrée + triée + rollups calculés.
pub fn requete_avec_rollups(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    vue_id: Uuid,
) -> Result<Vec<Entree>, ChaqaqError> {
    let db = repo.load(db_id)?;
    let entrees = requete(repo, db_id, vue_id)?;
    evaluer_rollups(repo, &db, entrees)
}

/// Agrège toutes les valeurs d'une colonne numérique sur l'ensemble des entrées.
pub fn agregat_colonne(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    prop_id: Uuid,
    agregat: Agregat,
) -> Result<ValeurPropriete, ChaqaqError> {
    let db = repo.load(db_id)?;
    let refs: Vec<&Entree> = db.entrees.iter().collect();
    Ok(calculer_agregat(&refs, prop_id, &agregat))
}

/// Regroupe les entrées d'une vue par valeur d'une propriété.
pub fn requete_groupee(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    vue_id: Uuid,
    grouper_par: Uuid,
) -> Result<Vec<Groupe>, ChaqaqError> {
    let entrees = requete(repo, db_id, vue_id)?;
    let mut map: HashMap<String, Groupe> = HashMap::new();

    for entree in entrees {
        let valeur = entree.valeurs.get(&grouper_par).cloned().unwrap_or(ValeurPropriete::Vide);
        let cle = cle_groupe(&valeur);
        map.entry(cle)
            .or_insert_with(|| Groupe { valeur: valeur.clone(), entrees: vec![] })
            .entrees.push(entree);
    }

    let mut groupes: Vec<Groupe> = map.into_values().collect();
    groupes.sort_by(|a, b| comparer_valeurs(&a.valeur, &b.valeur));
    Ok(groupes)
}

// ── Helpers internes ─────────────────────────────────────────────────────────

/// Retourne la date effective : valeur manuelle si renseignée, sinon `cree_le`.
fn date_effective<'a>(v: &'a ValeurPropriete, cree_le: &'a str) -> &'a str {
    match v {
        ValeurPropriete::Date(d) if !d.is_empty() => d.as_str(),
        _ => cree_le,
    }
}

fn calculer_agregat(entrees: &[&Entree], prop_id: Uuid, agregat: &Agregat) -> ValeurPropriete {
    let nums: Vec<f64> = entrees.iter()
        .filter_map(|e| e.valeurs.get(&prop_id))
        .filter_map(|v| if let ValeurPropriete::Nombre(n) = v { Some(*n) } else { None })
        .collect();

    let r = match agregat {
        Agregat::Compter  => entrees.len() as f64,
        Agregat::Somme    => nums.iter().sum(),
        Agregat::Moyenne  => if nums.is_empty() { 0.0 } else { nums.iter().sum::<f64>() / nums.len() as f64 },
        Agregat::Min      => nums.iter().cloned().fold(f64::INFINITY, f64::min),
        Agregat::Max      => nums.iter().cloned().fold(f64::NEG_INFINITY, f64::max),
    };
    ValeurPropriete::Nombre(r)
}

fn cle_groupe(v: &ValeurPropriete) -> String {
    match v {
        ValeurPropriete::Texte(s)            => s.clone(),
        ValeurPropriete::Selection(Some(s))  => s.clone(),
        ValeurPropriete::Nombre(n)           => n.to_string(),
        ValeurPropriete::Date(d)             => d.clone(),
        ValeurPropriete::Case(b)             => b.to_string(),
        _                                    => String::new(),
    }
}

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

    #[test]
    fn test_calculer_agregat_somme() {
        let prop_id = Uuid::new_v4();
        let entrees = vec![
            entree_avec_nombre(prop_id, 10.0),
            entree_avec_nombre(prop_id, 20.0),
            entree_avec_nombre(prop_id, 30.0),
        ];
        let refs: Vec<&Entree> = entrees.iter().collect();
        assert_eq!(calculer_agregat(&refs, prop_id, &Agregat::Somme), ValeurPropriete::Nombre(60.0));
    }

    #[test]
    fn test_calculer_agregat_compter() {
        let prop_id = Uuid::new_v4();
        let e1 = entree_avec_nombre(prop_id, 1.0);
        let e2 = entree_avec_nombre(prop_id, 2.0);
        let refs: Vec<&Entree> = vec![&e1, &e2];
        assert_eq!(calculer_agregat(&refs, prop_id, &Agregat::Compter), ValeurPropriete::Nombre(2.0));
    }

    #[test]
    fn test_calculer_agregat_moyenne() {
        let prop_id = Uuid::new_v4();
        let entrees = vec![
            entree_avec_nombre(prop_id, 10.0),
            entree_avec_nombre(prop_id, 20.0),
        ];
        let refs: Vec<&Entree> = entrees.iter().collect();
        assert_eq!(calculer_agregat(&refs, prop_id, &Agregat::Moyenne), ValeurPropriete::Nombre(15.0));
    }

    #[test]
    fn test_cle_groupe_texte() {
        assert_eq!(cle_groupe(&ValeurPropriete::Texte("A".to_string())), "A");
        assert_eq!(cle_groupe(&ValeurPropriete::Vide), String::new());
    }

    #[test]
    fn test_valeur_contient_texte() {
        assert!(valeur_contient(&ValeurPropriete::Texte("Bonjour monde".to_string()), "monde"));
        assert!(!valeur_contient(&ValeurPropriete::Texte("Bonjour".to_string()), "monde"));
    }

    #[test]
    fn test_valeur_contient_insensible_casse() {
        assert!(valeur_contient(&ValeurPropriete::Texte("Journal".to_string()), "journal"));
    }

    #[test]
    fn test_valeur_contient_vide_ne_match_pas() {
        assert!(!valeur_contient(&ValeurPropriete::Vide, "anything"));
        assert!(!valeur_contient(&ValeurPropriete::Nombre(42.0), "42"));
    }
}
