#![allow(dead_code)]
use std::collections::HashMap;
use uuid::Uuid;
use serde::{Serialize, Deserialize};
use chrono::Utc;
use crate::domain::document::InlineText;

// ── Types de propriétés (colonnes) ───────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Agregat {
    Compter,
    Somme,
    Moyenne,
    Min,
    Max,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ProprieteType {
    Titre,
    Texte,
    Nombre,
    Selection(Vec<String>),
    SelectionMultiple(Vec<String>),
    Date,
    Case,
    Url,
    Relation { db_id: Uuid },
    Rollup { relation_prop_id: Uuid, cible_prop_id: Uuid, agregat: Agregat },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Propriete {
    pub id: Uuid,
    pub nom: String,
    pub type_: ProprieteType,
}

impl Propriete {
    pub fn nouvelle(nom: impl Into<String>, type_: ProprieteType) -> Self {
        Self { id: Uuid::new_v4(), nom: nom.into(), type_ }
    }
}

// ── Valeurs des cellules ─────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ValeurPropriete {
    Titre(Vec<InlineText>),
    Texte(String),
    Nombre(f64),
    Selection(Option<String>),
    SelectionMultiple(Vec<String>),
    Date(String), // ISO 8601
    Case(bool),
    Url(String),
    Relation(Vec<Uuid>), // IDs d'entrées dans la database liée
    Vide,
}

// ── Entrées (lignes) ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entree {
    pub id: Uuid,
    /// Timestamp ISO 8601 auto-généré à la création — jamais modifié après.
    #[serde(default)]
    pub cree_le: String,
    pub valeurs: HashMap<Uuid, ValeurPropriete>,
}

impl Entree {
    pub fn nouvelle(valeurs: HashMap<Uuid, ValeurPropriete>) -> Self {
        Self {
            id: Uuid::new_v4(),
            cree_le: Utc::now().to_rfc3339(),
            valeurs,
        }
    }
}

// ── Vues ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum TypeVue {
    Tableau,
    Kanban { grouper_par: Uuid },
    Calendrier { propriete_id: Uuid },
    Galerie,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ConditionFiltre {
    Egal(ValeurPropriete),
    Contient(String),
    EstVide,
    EstPlein,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Filtre {
    pub propriete_id: Uuid,
    pub condition: ConditionFiltre,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Ordre {
    Croissant,
    Decroissant,
}

/// Détermine quelle date utiliser lors d'un tri.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub enum SourceTri {
    /// Tri standard sur la valeur de `propriete_id`.
    #[default]
    Propriete,
    /// Tri sur `cree_le` uniquement (date auto-générée, `propriete_id` ignoré).
    Creation,
    /// Utilise la valeur de `propriete_id` si elle est renseignée, sinon `cree_le`.
    /// Résout le cas journal : anciennes notes avec date manuelle + nouvelles notes sans.
    ManuellePuisCreation,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Tri {
    pub propriete_id: Uuid,
    pub ordre: Ordre,
    #[serde(default)]
    pub source: SourceTri,
}

impl Tri {
    pub fn par_propriete(propriete_id: Uuid, ordre: Ordre) -> Self {
        Self { propriete_id, ordre, source: SourceTri::Propriete }
    }

    /// Tri par date auto-générée. `propriete_id` peut être `Uuid::nil()`.
    pub fn par_creation(ordre: Ordre) -> Self {
        Self { propriete_id: Uuid::nil(), ordre, source: SourceTri::Creation }
    }

    /// Date manuelle si renseignée, sinon date de création automatique.
    pub fn manuelle_puis_creation(propriete_id: Uuid, ordre: Ordre) -> Self {
        Self { propriete_id, ordre, source: SourceTri::ManuellePuisCreation }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Vue {
    pub id: Uuid,
    pub nom: String,
    pub type_: TypeVue,
    pub filtres: Vec<Filtre>,
    pub tris: Vec<Tri>,
}

impl Vue {
    pub fn nouvelle(nom: impl Into<String>, type_: TypeVue) -> Self {
        Self {
            id: Uuid::new_v4(),
            nom: nom.into(),
            type_,
            filtres: vec![],
            tris: vec![],
        }
    }
}

// ── Groupement ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Groupe {
    pub valeur: ValeurPropriete, // valeur commune du groupe (Vide = sans valeur)
    pub entrees: Vec<Entree>,
}

// ── Database ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DatabaseMeta {
    pub id: Uuid,
    pub titre: Vec<InlineText>,
    /// Timestamp ISO 8601 de la dernière modification — géré par l'infrastructure.
    /// Vide si le backend ne le fournit pas (DatabaseStore JSON, mock).
    #[serde(default)]
    pub updated_at: String,
    /// Timestamp ISO 8601 de création — setté à l'INSERT, jamais modifié.
    /// Vide si le backend ne le fournit pas (DatabaseStore JSON, mock).
    #[serde(default)]
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Database {
    pub id: Uuid,
    pub titre: Vec<InlineText>,
    pub proprietes: Vec<Propriete>,
    pub entrees: Vec<Entree>,
    pub vues: Vec<Vue>,
}

impl Database {
    pub fn nouvelle(titre: Vec<InlineText>, proprietes: Vec<Propriete>) -> Self {
        let vue_defaut = Vue::nouvelle("Tableau", TypeVue::Tableau);
        Self {
            id: Uuid::new_v4(),
            titre,
            proprietes,
            entrees: vec![],
            vues: vec![vue_defaut],
        }
    }

    pub fn meta(&self) -> DatabaseMeta {
        DatabaseMeta { id: self.id, titre: self.titre.clone(), updated_at: String::new(), created_at: String::new() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn titre(s: &str) -> Vec<InlineText> {
        vec![InlineText { content: s.to_string(), styles: vec![] }]
    }

    #[test]
    fn test_nouvelle_database_a_vue_tableau_par_defaut() {
        let db = Database::nouvelle(titre("Projets"), vec![]);
        assert_eq!(db.vues.len(), 1);
        assert_eq!(db.vues[0].type_, TypeVue::Tableau);
        assert_eq!(db.vues[0].nom, "Tableau");
    }

    #[test]
    fn test_meta_extrait_id_et_titre() {
        let db = Database::nouvelle(titre("Tâches"), vec![]);
        let meta = db.meta();
        assert_eq!(meta.id, db.id);
        assert_eq!(meta.titre, db.titre);
    }

    #[test]
    fn test_entree_nouvelle_genere_id_unique() {
        let e1 = Entree::nouvelle(HashMap::new());
        let e2 = Entree::nouvelle(HashMap::new());
        assert_ne!(e1.id, e2.id);
    }

    #[test]
    fn test_propriete_nouvelle_genere_id_unique() {
        let p1 = Propriete::nouvelle("Nom", ProprieteType::Titre);
        let p2 = Propriete::nouvelle("Nom", ProprieteType::Titre);
        assert_ne!(p1.id, p2.id);
    }

    #[test]
    fn test_vue_nouvelle_sans_filtres_ni_tris() {
        let vue = Vue::nouvelle("Board", TypeVue::Galerie);
        assert!(vue.filtres.is_empty());
        assert!(vue.tris.is_empty());
    }

    #[test]
    fn test_nouvelle_database_sans_entrees() {
        let db = Database::nouvelle(titre("Vide"), vec![]);
        assert!(db.entrees.is_empty());
    }

    #[test]
    fn test_relation_prop_type() {
        let db_id = Uuid::new_v4();
        let prop = Propriete::nouvelle("Tâches", ProprieteType::Relation { db_id });
        assert_eq!(prop.type_, ProprieteType::Relation { db_id });
    }

    #[test]
    fn test_rollup_prop_type() {
        let rel_id = Uuid::new_v4();
        let cible_id = Uuid::new_v4();
        let prop = Propriete::nouvelle(
            "Nb tâches",
            ProprieteType::Rollup {
                relation_prop_id: rel_id,
                cible_prop_id: cible_id,
                agregat: Agregat::Compter,
            },
        );
        assert!(matches!(prop.type_, ProprieteType::Rollup { .. }));
    }

    #[test]
    fn test_valeur_relation_stocke_ids() {
        let ids = vec![Uuid::new_v4(), Uuid::new_v4()];
        let v = ValeurPropriete::Relation(ids.clone());
        assert_eq!(v, ValeurPropriete::Relation(ids));
    }

    #[test]
    fn test_entree_nouvelle_a_cree_le_non_vide() {
        let e = Entree::nouvelle(HashMap::new());
        assert!(!e.cree_le.is_empty());
        // ISO 8601 commence par l'année
        assert!(e.cree_le.starts_with("20"));
    }

    #[test]
    fn test_tri_par_creation_ignore_propriete_id() {
        let t = Tri::par_creation(Ordre::Decroissant);
        assert_eq!(t.source, SourceTri::Creation);
    }

    #[test]
    fn test_tri_manuelle_puis_creation() {
        let id = Uuid::new_v4();
        let t = Tri::manuelle_puis_creation(id, Ordre::Croissant);
        assert_eq!(t.source, SourceTri::ManuellePuisCreation);
        assert_eq!(t.propriete_id, id);
    }

    #[test]
    fn test_groupe_regroupe_entrees() {
        let groupe = Groupe {
            valeur: ValeurPropriete::Texte("En cours".to_string()),
            entrees: vec![Entree::nouvelle(HashMap::new())],
        };
        assert_eq!(groupe.entrees.len(), 1);
    }
}
