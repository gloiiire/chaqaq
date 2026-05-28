#![allow(dead_code)]
use std::collections::HashMap;
use uuid::Uuid;
use serde::{Serialize, Deserialize};
use crate::domain::document::InlineText;

// ── Types de propriétés (colonnes) ───────────────────────────────────────────

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
    Vide,
}

// ── Entrées (lignes) ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entree {
    pub id: Uuid,
    pub valeurs: HashMap<Uuid, ValeurPropriete>,
}

impl Entree {
    pub fn nouvelle(valeurs: HashMap<Uuid, ValeurPropriete>) -> Self {
        Self { id: Uuid::new_v4(), valeurs }
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

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Tri {
    pub propriete_id: Uuid,
    pub ordre: Ordre,
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

// ── Database ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DatabaseMeta {
    pub id: Uuid,
    pub titre: Vec<InlineText>,
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
        DatabaseMeta { id: self.id, titre: self.titre.clone() }
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
}
