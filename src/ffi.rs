use std::collections::HashMap;

use serde::de::DeserializeOwned;
use uuid::Uuid;

use crate::application::error::ChaqaqError as CoreError;
use crate::application::{database_use_cases, use_cases};
use crate::domain::database::{
    Agregat, DatabaseMeta, Entree, Filtre, Propriete, Tri, ValeurPropriete, Vue,
};
use crate::domain::document::{Block, BlockContent, DocumentMeta};
use crate::domain::parser::parse_inline;
use crate::infrastructure::sqlite_database_store::SqliteDatabaseStore;
use crate::infrastructure::sqlite_document_store::SqliteDocumentStore;

// ── Erreur FFI ────────────────────────────────────────────────────────────────

#[derive(Debug)]
pub enum ChaqaqError {
    NonTrouve { id: String },
    OperationInvalide { detail: String },
    Stockage { detail: String },
}

impl std::fmt::Display for ChaqaqError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NonTrouve { id } => write!(f, "non trouvé : {id}"),
            Self::OperationInvalide { detail } => write!(f, "opération invalide : {detail}"),
            Self::Stockage { detail } => write!(f, "stockage : {detail}"),
        }
    }
}

impl std::error::Error for ChaqaqError {}

impl From<CoreError> for ChaqaqError {
    fn from(e: CoreError) -> Self {
        match e {
            CoreError::NonTrouve(id) => Self::NonTrouve { id: id.to_string() },
            CoreError::OperationInvalide(msg) => Self::OperationInvalide { detail: msg },
            CoreError::Io(e) => Self::Stockage {
                detail: e.to_string(),
            },
            CoreError::Json(e) => Self::Stockage {
                detail: e.to_string(),
            },
            CoreError::Db(msg) => Self::Stockage { detail: msg },
        }
    }
}

// ── Types dictionnaire ────────────────────────────────────────────────────────

pub struct DocumentMetaFfi {
    pub id: String,
    pub title_plain: String,
    pub title_json: String,
    pub cover: Option<String>,
    pub updated_at: String,
    pub created_at: String,
}

pub struct DatabaseMetaFfi {
    pub id: String,
    pub titre_plain: String,
    pub titre_json: String,
    pub updated_at: String,
    pub created_at: String,
}

fn doc_meta_vers_ffi(m: DocumentMeta) -> DocumentMetaFfi {
    let title_plain = m
        .title
        .iter()
        .map(|i| i.content.as_str())
        .collect::<Vec<_>>()
        .join("");
    let title_json = serde_json::to_string(&m.title).unwrap_or_default();
    DocumentMetaFfi {
        id: m.id.to_string(),
        title_plain,
        title_json,
        cover: m.cover,
        updated_at: m.updated_at,
        created_at: m.created_at,
    }
}

fn db_meta_vers_ffi(m: DatabaseMeta) -> DatabaseMetaFfi {
    let titre_plain = m
        .titre
        .iter()
        .map(|i| i.content.as_str())
        .collect::<Vec<_>>()
        .join("");
    let titre_json = serde_json::to_string(&m.titre).unwrap_or_default();
    DatabaseMetaFfi {
        id: m.id.to_string(),
        titre_plain,
        titre_json,
        updated_at: m.updated_at,
        created_at: m.created_at,
    }
}

fn parse_uuid(s: &str) -> Result<Uuid, ChaqaqError> {
    Uuid::parse_str(s).map_err(|_| ChaqaqError::OperationInvalide {
        detail: format!("UUID invalide : {s}"),
    })
}

fn parse_uuids(ids: Vec<String>) -> Result<Vec<Uuid>, ChaqaqError> {
    ids.iter().map(|s| parse_uuid(s)).collect()
}

fn parse_json<T: DeserializeOwned>(json: &str) -> Result<T, ChaqaqError> {
    serde_json::from_str(json).map_err(|e| ChaqaqError::OperationInvalide {
        detail: e.to_string(),
    })
}

fn to_json<T: serde::Serialize>(value: &T) -> Result<String, ChaqaqError> {
    serde_json::to_string(value).map_err(|e| ChaqaqError::Stockage {
        detail: e.to_string(),
    })
}

fn bloc_id(bloc: Block) -> String {
    bloc.id.to_string()
}

// ── Façade principale ─────────────────────────────────────────────────────────

pub struct ChaqaqApi {
    docs: SqliteDocumentStore,
    dbs: SqliteDatabaseStore,
}

impl ChaqaqApi {
    pub fn new(chemin_db: String) -> Result<Self, ChaqaqError> {
        let docs = SqliteDocumentStore::nouveau(&chemin_db).map_err(ChaqaqError::from)?;
        let dbs = SqliteDatabaseStore::nouveau(&chemin_db).map_err(ChaqaqError::from)?;
        Ok(Self { docs, dbs })
    }

    // ── Documents ─────────────────────────────────────────────

    pub fn creer_document(&self, titre: String) -> Result<String, ChaqaqError> {
        let doc = use_cases::creer_document(&self.docs, &titre).map_err(ChaqaqError::from)?;
        Ok(doc.id.to_string())
    }

    pub fn obtenir_document_json(&self, id: String) -> Result<String, ChaqaqError> {
        let uuid = parse_uuid(&id)?;
        let doc = use_cases::obtenir_document(&self.docs, uuid).map_err(ChaqaqError::from)?;
        serde_json::to_string(&doc).map_err(|e| ChaqaqError::Stockage {
            detail: e.to_string(),
        })
    }

    pub fn lister_documents(&self) -> Result<Vec<DocumentMetaFfi>, ChaqaqError> {
        let metas = use_cases::lister_documents(&self.docs).map_err(ChaqaqError::from)?;
        Ok(metas.into_iter().map(doc_meta_vers_ffi).collect())
    }

    pub fn supprimer_document(&self, id: String) -> Result<(), ChaqaqError> {
        let uuid = parse_uuid(&id)?;
        use_cases::supprimer_document(&self.docs, uuid).map_err(ChaqaqError::from)
    }

    pub fn modifier_titre_document(
        &self,
        id: String,
        nouveau_titre: String,
    ) -> Result<(), ChaqaqError> {
        let uuid = parse_uuid(&id)?;
        use_cases::modifier_titre_document(&self.docs, uuid, &nouveau_titre)
            .map_err(ChaqaqError::from)
    }

    pub fn modifier_couverture_document(
        &self,
        id: String,
        couverture: Option<String>,
    ) -> Result<(), ChaqaqError> {
        let uuid = parse_uuid(&id)?;
        use_cases::modifier_couverture_document(&self.docs, uuid, couverture)
            .map_err(ChaqaqError::from)
    }

    pub fn ajouter_bloc(
        &self,
        doc_id: String,
        bloc_content_json: String,
    ) -> Result<String, ChaqaqError> {
        let uuid = parse_uuid(&doc_id)?;
        let contenu: BlockContent = parse_json(&bloc_content_json)?;
        let doc = use_cases::ajouter_bloc(&self.docs, uuid, contenu).map_err(ChaqaqError::from)?;
        doc.blocks
            .last()
            .map(|b| b.id.to_string())
            .ok_or_else(|| ChaqaqError::OperationInvalide {
                detail: "bloc introuvable après ajout".to_string(),
            })
    }

    pub fn modifier_bloc(
        &self,
        doc_id: String,
        bloc_id: String,
        contenu_json: String,
    ) -> Result<(), ChaqaqError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let bloc_uuid = parse_uuid(&bloc_id)?;
        let contenu: BlockContent = parse_json(&contenu_json)?;
        use_cases::modifier_bloc(&self.docs, doc_uuid, bloc_uuid, contenu)
            .map_err(ChaqaqError::from)
    }

    pub fn supprimer_bloc(&self, doc_id: String, bloc_id: String) -> Result<(), ChaqaqError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let bloc_uuid = parse_uuid(&bloc_id)?;
        use_cases::supprimer_bloc(&self.docs, doc_uuid, bloc_uuid).map_err(ChaqaqError::from)
    }

    pub fn reordonner_blocs(&self, doc_id: String, ordre: Vec<String>) -> Result<(), ChaqaqError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let uuids = parse_uuids(ordre)?;
        use_cases::reordonner_blocs(&self.docs, doc_uuid, uuids).map_err(ChaqaqError::from)
    }

    pub fn ajouter_bloc_enfant(
        &self,
        doc_id: String,
        parent_id: String,
        bloc_content_json: String,
    ) -> Result<String, ChaqaqError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let parent_uuid = parse_uuid(&parent_id)?;
        let contenu: BlockContent = parse_json(&bloc_content_json)?;
        use_cases::ajouter_bloc_enfant(&self.docs, doc_uuid, parent_uuid, contenu)
            .map(bloc_id)
            .map_err(ChaqaqError::from)
    }

    pub fn reordonner_blocs_enfants(
        &self,
        doc_id: String,
        parent_id: String,
        ordre: Vec<String>,
    ) -> Result<(), ChaqaqError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let parent_uuid = parse_uuid(&parent_id)?;
        let uuids = parse_uuids(ordre)?;
        use_cases::reordonner_blocs_enfants(&self.docs, doc_uuid, parent_uuid, uuids)
            .map_err(ChaqaqError::from)
    }

    pub fn deplacer_bloc(
        &self,
        doc_id: String,
        bloc_id: String,
        nouveau_parent_id: Option<String>,
    ) -> Result<(), ChaqaqError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let bloc_uuid = parse_uuid(&bloc_id)?;
        let parent_uuid = nouveau_parent_id.as_deref().map(parse_uuid).transpose()?;
        use_cases::deplacer_bloc(&self.docs, doc_uuid, bloc_uuid, parent_uuid)
            .map_err(ChaqaqError::from)
    }

    pub fn rechercher_documents(&self, query: String) -> Result<Vec<DocumentMetaFfi>, ChaqaqError> {
        let metas =
            use_cases::rechercher_documents(&self.docs, &query).map_err(ChaqaqError::from)?;
        Ok(metas.into_iter().map(doc_meta_vers_ffi).collect())
    }

    pub fn rechercher_dans_blocs(
        &self,
        query: String,
    ) -> Result<Vec<DocumentMetaFfi>, ChaqaqError> {
        let metas =
            use_cases::rechercher_dans_blocs(&self.docs, &query).map_err(ChaqaqError::from)?;
        Ok(metas.into_iter().map(doc_meta_vers_ffi).collect())
    }
}

// ── Façade : databases ────────────────────────────────────────────────────────

impl ChaqaqApi {
    pub fn creer_database(&self, titre: String) -> Result<String, ChaqaqError> {
        let db = database_use_cases::creer_database(&self.dbs, parse_inline(&titre), vec![])
            .map_err(ChaqaqError::from)?;
        Ok(db.id.to_string())
    }

    pub fn obtenir_database_json(&self, id: String) -> Result<String, ChaqaqError> {
        let uuid = parse_uuid(&id)?;
        let db =
            database_use_cases::obtenir_database(&self.dbs, uuid).map_err(ChaqaqError::from)?;
        serde_json::to_string(&db).map_err(|e| ChaqaqError::Stockage {
            detail: e.to_string(),
        })
    }

    pub fn lister_databases(&self) -> Result<Vec<DatabaseMetaFfi>, ChaqaqError> {
        let metas = database_use_cases::lister_databases(&self.dbs).map_err(ChaqaqError::from)?;
        Ok(metas.into_iter().map(db_meta_vers_ffi).collect())
    }

    pub fn supprimer_database(&self, id: String) -> Result<(), ChaqaqError> {
        let uuid = parse_uuid(&id)?;
        database_use_cases::supprimer_database(&self.dbs, uuid).map_err(ChaqaqError::from)
    }

    pub fn ajouter_entree(
        &self,
        db_id: String,
        valeurs_json: String,
    ) -> Result<String, ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let valeurs: HashMap<Uuid, ValeurPropriete> = parse_json(&valeurs_json)?;
        let entree = database_use_cases::ajouter_entree(&self.dbs, db_uuid, valeurs)
            .map_err(ChaqaqError::from)?;
        Ok(entree.id.to_string())
    }

    pub fn modifier_entree(
        &self,
        db_id: String,
        entree_id: String,
        valeurs_json: String,
    ) -> Result<(), ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entree_uuid = parse_uuid(&entree_id)?;
        let valeurs: HashMap<Uuid, ValeurPropriete> = parse_json(&valeurs_json)?;
        database_use_cases::modifier_entree(&self.dbs, db_uuid, entree_uuid, valeurs)
            .map_err(ChaqaqError::from)
    }

    pub fn supprimer_entree(&self, db_id: String, entree_id: String) -> Result<(), ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entree_uuid = parse_uuid(&entree_id)?;
        database_use_cases::supprimer_entree(&self.dbs, db_uuid, entree_uuid)
            .map_err(ChaqaqError::from)
    }

    pub fn ajouter_propriete(
        &self,
        db_id: String,
        propriete_json: String,
    ) -> Result<(), ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let propriete: Propriete = parse_json(&propriete_json)?;
        database_use_cases::ajouter_propriete(&self.dbs, db_uuid, propriete)
            .map_err(ChaqaqError::from)
    }

    pub fn renommer_propriete(
        &self,
        db_id: String,
        propriete_id: String,
        nouveau_nom: String,
    ) -> Result<(), ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let prop_uuid = parse_uuid(&propriete_id)?;
        database_use_cases::renommer_propriete(&self.dbs, db_uuid, prop_uuid, &nouveau_nom)
            .map_err(ChaqaqError::from)
    }

    pub fn supprimer_propriete(
        &self,
        db_id: String,
        propriete_id: String,
    ) -> Result<(), ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let prop_uuid = parse_uuid(&propriete_id)?;
        database_use_cases::supprimer_propriete(&self.dbs, db_uuid, prop_uuid)
            .map_err(ChaqaqError::from)
    }

    pub fn ajouter_vue(&self, db_id: String, vue_json: String) -> Result<String, ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let vue: Vue = parse_json(&vue_json)?;
        let vue =
            database_use_cases::ajouter_vue(&self.dbs, db_uuid, vue).map_err(ChaqaqError::from)?;
        Ok(vue.id.to_string())
    }

    pub fn modifier_vue(
        &self,
        db_id: String,
        vue_id: String,
        filtres_json: String,
        tris_json: String,
    ) -> Result<(), ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let vue_uuid = parse_uuid(&vue_id)?;
        let filtres: Vec<Filtre> = parse_json(&filtres_json)?;
        let tris: Vec<Tri> = parse_json(&tris_json)?;
        database_use_cases::modifier_vue(&self.dbs, db_uuid, vue_uuid, filtres, tris)
            .map_err(ChaqaqError::from)
    }

    pub fn supprimer_vue(&self, db_id: String, vue_id: String) -> Result<(), ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let vue_uuid = parse_uuid(&vue_id)?;
        database_use_cases::supprimer_vue(&self.dbs, db_uuid, vue_uuid).map_err(ChaqaqError::from)
    }

    pub fn requete_database_json(
        &self,
        db_id: String,
        vue_id: String,
    ) -> Result<String, ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let vue_uuid = parse_uuid(&vue_id)?;
        let entrees: Vec<Entree> =
            database_use_cases::requete(&self.dbs, db_uuid, vue_uuid).map_err(ChaqaqError::from)?;
        to_json(&entrees)
    }

    pub fn requete_database_avec_rollups_json(
        &self,
        db_id: String,
        vue_id: String,
    ) -> Result<String, ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let vue_uuid = parse_uuid(&vue_id)?;
        let entrees: Vec<Entree> =
            database_use_cases::requete_avec_rollups(&self.dbs, db_uuid, vue_uuid)
                .map_err(ChaqaqError::from)?;
        to_json(&entrees)
    }

    pub fn requete_groupee_database_json(
        &self,
        db_id: String,
        vue_id: String,
        grouper_par: String,
    ) -> Result<String, ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let vue_uuid = parse_uuid(&vue_id)?;
        let prop_uuid = parse_uuid(&grouper_par)?;
        let groupes = database_use_cases::requete_groupee(&self.dbs, db_uuid, vue_uuid, prop_uuid)
            .map_err(ChaqaqError::from)?;
        to_json(&groupes)
    }

    pub fn agregat_colonne_database_json(
        &self,
        db_id: String,
        propriete_id: String,
        agregat_json: String,
    ) -> Result<String, ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let prop_uuid = parse_uuid(&propriete_id)?;
        let agregat: Agregat = parse_json(&agregat_json)?;
        let valeur = database_use_cases::agregat_colonne(&self.dbs, db_uuid, prop_uuid, agregat)
            .map_err(ChaqaqError::from)?;
        to_json(&valeur)
    }

    pub fn rechercher_entrees_database_json(
        &self,
        db_id: String,
        query: String,
    ) -> Result<String, ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entrees = database_use_cases::rechercher_entrees(&self.dbs, db_uuid, &query)
            .map_err(ChaqaqError::from)?;
        to_json(&entrees)
    }
}
