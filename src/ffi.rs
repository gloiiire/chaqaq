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
    NotFound { id: String },
    InvalidOperation { detail: String },
    Storage { detail: String },
}

impl std::fmt::Display for ChaqaqError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound { id } => write!(f, "non trouvé : {id}"),
            Self::InvalidOperation { detail } => write!(f, "opération invalide : {detail}"),
            Self::Storage { detail } => write!(f, "stockage : {detail}"),
        }
    }
}

impl std::error::Error for ChaqaqError {}

impl From<CoreError> for ChaqaqError {
    fn from(e: CoreError) -> Self {
        match e {
            CoreError::NotFound(id) => Self::NotFound { id: id.to_string() },
            CoreError::InvalidOperation(msg) => Self::InvalidOperation { detail: msg },
            CoreError::Io(e) => Self::Storage {
                detail: e.to_string(),
            },
            CoreError::Json(e) => Self::Storage {
                detail: e.to_string(),
            },
            CoreError::Db(msg) => Self::Storage { detail: msg },
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
    pub title_plain: String,
    pub title_json: String,
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
    let title_plain = m
        .title
        .iter()
        .map(|i| i.content.as_str())
        .collect::<Vec<_>>()
        .join("");
    let title_json = serde_json::to_string(&m.title).unwrap_or_default();
    DatabaseMetaFfi {
        id: m.id.to_string(),
        title_plain,
        title_json,
        updated_at: m.updated_at,
        created_at: m.created_at,
    }
}

fn parse_uuid(s: &str) -> Result<Uuid, ChaqaqError> {
    Uuid::parse_str(s).map_err(|_| ChaqaqError::InvalidOperation {
        detail: format!("UUID invalide : {s}"),
    })
}

fn parse_uuids(ids: Vec<String>) -> Result<Vec<Uuid>, ChaqaqError> {
    ids.iter().map(|s| parse_uuid(s)).collect()
}

fn parse_json<T: DeserializeOwned>(json: &str) -> Result<T, ChaqaqError> {
    serde_json::from_str(json).map_err(|e| ChaqaqError::InvalidOperation {
        detail: e.to_string(),
    })
}

fn to_json<T: serde::Serialize>(value: &T) -> Result<String, ChaqaqError> {
    serde_json::to_string(value).map_err(|e| ChaqaqError::Storage {
        detail: e.to_string(),
    })
}

fn block_id(bloc: Block) -> String {
    bloc.id.to_string()
}

// ── Façade principale ─────────────────────────────────────────────────────────

pub struct ChaqaqApi {
    docs: SqliteDocumentStore,
    dbs: SqliteDatabaseStore,
}

impl ChaqaqApi {
    pub fn new(db_path: String) -> Result<Self, ChaqaqError> {
        let docs = SqliteDocumentStore::nouveau(&db_path).map_err(ChaqaqError::from)?;
        let dbs = SqliteDatabaseStore::nouveau(&db_path).map_err(ChaqaqError::from)?;
        Ok(Self { docs, dbs })
    }

    // ── Documents ─────────────────────────────────────────────

    pub fn create_document(&self, title: String) -> Result<String, ChaqaqError> {
        let doc = use_cases::create_document(&self.docs, &title).map_err(ChaqaqError::from)?;
        Ok(doc.id.to_string())
    }

    pub fn get_document_json(&self, id: String) -> Result<String, ChaqaqError> {
        let uuid = parse_uuid(&id)?;
        let doc = use_cases::get_document(&self.docs, uuid).map_err(ChaqaqError::from)?;
        serde_json::to_string(&doc).map_err(|e| ChaqaqError::Storage {
            detail: e.to_string(),
        })
    }

    pub fn list_documents(&self) -> Result<Vec<DocumentMetaFfi>, ChaqaqError> {
        let metas = use_cases::list_documents(&self.docs).map_err(ChaqaqError::from)?;
        Ok(metas.into_iter().map(doc_meta_vers_ffi).collect())
    }

    pub fn delete_document(&self, id: String) -> Result<(), ChaqaqError> {
        let uuid = parse_uuid(&id)?;
        use_cases::delete_document(&self.docs, uuid).map_err(ChaqaqError::from)
    }

    pub fn update_document_title(
        &self,
        id: String,
        new_title: String,
    ) -> Result<(), ChaqaqError> {
        let uuid = parse_uuid(&id)?;
        use_cases::update_document_title(&self.docs, uuid, &new_title)
            .map_err(ChaqaqError::from)
    }

    pub fn update_document_cover(
        &self,
        id: String,
        cover: Option<String>,
    ) -> Result<(), ChaqaqError> {
        let uuid = parse_uuid(&id)?;
        use_cases::update_document_cover(&self.docs, uuid, cover)
            .map_err(ChaqaqError::from)
    }

    pub fn add_block(
        &self,
        doc_id: String,
        block_content_json: String,
    ) -> Result<String, ChaqaqError> {
        let uuid = parse_uuid(&doc_id)?;
        let content: BlockContent = parse_json(&block_content_json)?;
        let doc = use_cases::add_block(&self.docs, uuid, content).map_err(ChaqaqError::from)?;
        doc.blocks
            .last()
            .map(|b| b.id.to_string())
            .ok_or_else(|| ChaqaqError::InvalidOperation {
                detail: "bloc introuvable après ajout".to_string(),
            })
    }

    pub fn update_block(
        &self,
        doc_id: String,
        block_id: String,
        content_json: String,
    ) -> Result<(), ChaqaqError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let bloc_uuid = parse_uuid(&block_id)?;
        let content: BlockContent = parse_json(&content_json)?;
        use_cases::update_block(&self.docs, doc_uuid, bloc_uuid, content)
            .map_err(ChaqaqError::from)
    }

    pub fn delete_block(&self, doc_id: String, block_id: String) -> Result<(), ChaqaqError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let bloc_uuid = parse_uuid(&block_id)?;
        use_cases::delete_block(&self.docs, doc_uuid, bloc_uuid).map_err(ChaqaqError::from)
    }

    pub fn reorder_blocks(&self, doc_id: String, order: Vec<String>) -> Result<(), ChaqaqError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let uuids = parse_uuids(order)?;
        use_cases::reorder_blocks(&self.docs, doc_uuid, uuids).map_err(ChaqaqError::from)
    }

    pub fn add_child_block(
        &self,
        doc_id: String,
        parent_id: String,
        block_content_json: String,
    ) -> Result<String, ChaqaqError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let parent_uuid = parse_uuid(&parent_id)?;
        let content: BlockContent = parse_json(&block_content_json)?;
        use_cases::add_child_block(&self.docs, doc_uuid, parent_uuid, content)
            .map(block_id)
            .map_err(ChaqaqError::from)
    }

    pub fn reorder_child_blocks(
        &self,
        doc_id: String,
        parent_id: String,
        order: Vec<String>,
    ) -> Result<(), ChaqaqError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let parent_uuid = parse_uuid(&parent_id)?;
        let uuids = parse_uuids(order)?;
        use_cases::reorder_child_blocks(&self.docs, doc_uuid, parent_uuid, uuids)
            .map_err(ChaqaqError::from)
    }

    pub fn move_block(
        &self,
        doc_id: String,
        block_id: String,
        new_parent_id: Option<String>,
    ) -> Result<(), ChaqaqError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let bloc_uuid = parse_uuid(&block_id)?;
        let parent_uuid = new_parent_id.as_deref().map(parse_uuid).transpose()?;
        use_cases::move_block(&self.docs, doc_uuid, bloc_uuid, parent_uuid)
            .map_err(ChaqaqError::from)
    }

    pub fn search_documents(&self, query: String) -> Result<Vec<DocumentMetaFfi>, ChaqaqError> {
        let metas =
            use_cases::search_documents(&self.docs, &query).map_err(ChaqaqError::from)?;
        Ok(metas.into_iter().map(doc_meta_vers_ffi).collect())
    }

    pub fn search_in_blocks(
        &self,
        query: String,
    ) -> Result<Vec<DocumentMetaFfi>, ChaqaqError> {
        let metas =
            use_cases::search_in_blocks(&self.docs, &query).map_err(ChaqaqError::from)?;
        Ok(metas.into_iter().map(doc_meta_vers_ffi).collect())
    }
}

// ── Façade : databases ────────────────────────────────────────────────────────

impl ChaqaqApi {
    pub fn create_database(&self, title: String) -> Result<String, ChaqaqError> {
        let db = database_use_cases::create_database(&self.dbs, parse_inline(&title), vec![])
            .map_err(ChaqaqError::from)?;
        Ok(db.id.to_string())
    }

    pub fn get_database_json(&self, id: String) -> Result<String, ChaqaqError> {
        let uuid = parse_uuid(&id)?;
        let db =
            database_use_cases::get_database(&self.dbs, uuid).map_err(ChaqaqError::from)?;
        serde_json::to_string(&db).map_err(|e| ChaqaqError::Storage {
            detail: e.to_string(),
        })
    }

    pub fn list_databases(&self) -> Result<Vec<DatabaseMetaFfi>, ChaqaqError> {
        let metas = database_use_cases::list_databases(&self.dbs).map_err(ChaqaqError::from)?;
        Ok(metas.into_iter().map(db_meta_vers_ffi).collect())
    }

    pub fn delete_database(&self, id: String) -> Result<(), ChaqaqError> {
        let uuid = parse_uuid(&id)?;
        database_use_cases::delete_database(&self.dbs, uuid).map_err(ChaqaqError::from)
    }

    pub fn add_entry(
        &self,
        db_id: String,
        values_json: String,
    ) -> Result<String, ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let valeurs: HashMap<Uuid, ValeurPropriete> = parse_json(&values_json)?;
        let entree = database_use_cases::add_entry(&self.dbs, db_uuid, valeurs)
            .map_err(ChaqaqError::from)?;
        Ok(entree.id.to_string())
    }

    pub fn update_entry(
        &self,
        db_id: String,
        entry_id: String,
        values_json: String,
    ) -> Result<(), ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entree_uuid = parse_uuid(&entry_id)?;
        let valeurs: HashMap<Uuid, ValeurPropriete> = parse_json(&values_json)?;
        database_use_cases::update_entry(&self.dbs, db_uuid, entree_uuid, valeurs)
            .map_err(ChaqaqError::from)
    }

    pub fn delete_entry(&self, db_id: String, entry_id: String) -> Result<(), ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entree_uuid = parse_uuid(&entry_id)?;
        database_use_cases::delete_entry(&self.dbs, db_uuid, entree_uuid)
            .map_err(ChaqaqError::from)
    }

    pub fn add_property(
        &self,
        db_id: String,
        property_json: String,
    ) -> Result<(), ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let propriete: Propriete = parse_json(&property_json)?;
        database_use_cases::add_property(&self.dbs, db_uuid, propriete)
            .map_err(ChaqaqError::from)
    }

    pub fn rename_property(
        &self,
        db_id: String,
        property_id: String,
        new_name: String,
    ) -> Result<(), ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let prop_uuid = parse_uuid(&property_id)?;
        database_use_cases::rename_property(&self.dbs, db_uuid, prop_uuid, &new_name)
            .map_err(ChaqaqError::from)
    }

    pub fn delete_property(
        &self,
        db_id: String,
        property_id: String,
    ) -> Result<(), ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let prop_uuid = parse_uuid(&property_id)?;
        database_use_cases::delete_property(&self.dbs, db_uuid, prop_uuid)
            .map_err(ChaqaqError::from)
    }

    pub fn add_view(&self, db_id: String, view_json: String) -> Result<String, ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let vue: Vue = parse_json(&view_json)?;
        let vue =
            database_use_cases::add_view(&self.dbs, db_uuid, vue).map_err(ChaqaqError::from)?;
        Ok(vue.id.to_string())
    }

    pub fn update_view(
        &self,
        db_id: String,
        view_id: String,
        filters_json: String,
        sorts_json: String,
    ) -> Result<(), ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let vue_uuid = parse_uuid(&view_id)?;
        let filtres: Vec<Filtre> = parse_json(&filters_json)?;
        let tris: Vec<Tri> = parse_json(&sorts_json)?;
        database_use_cases::update_view(&self.dbs, db_uuid, vue_uuid, filtres, tris)
            .map_err(ChaqaqError::from)
    }

    pub fn delete_view(&self, db_id: String, view_id: String) -> Result<(), ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let vue_uuid = parse_uuid(&view_id)?;
        database_use_cases::delete_view(&self.dbs, db_uuid, vue_uuid).map_err(ChaqaqError::from)
    }

    pub fn query_database_json(
        &self,
        db_id: String,
        view_id: String,
    ) -> Result<String, ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let vue_uuid = parse_uuid(&view_id)?;
        let entrees: Vec<Entree> =
            database_use_cases::requete(&self.dbs, db_uuid, vue_uuid).map_err(ChaqaqError::from)?;
        to_json(&entrees)
    }

    pub fn query_database_with_rollups_json(
        &self,
        db_id: String,
        view_id: String,
    ) -> Result<String, ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let vue_uuid = parse_uuid(&view_id)?;
        let entrees: Vec<Entree> =
            database_use_cases::query_with_rollups(&self.dbs, db_uuid, vue_uuid)
                .map_err(ChaqaqError::from)?;
        to_json(&entrees)
    }

    pub fn grouped_query_database_json(
        &self,
        db_id: String,
        view_id: String,
        group_by: String,
    ) -> Result<String, ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let vue_uuid = parse_uuid(&view_id)?;
        let prop_uuid = parse_uuid(&group_by)?;
        let groupes = database_use_cases::grouped_query(&self.dbs, db_uuid, vue_uuid, prop_uuid)
            .map_err(ChaqaqError::from)?;
        to_json(&groupes)
    }

    pub fn column_aggregate_database_json(
        &self,
        db_id: String,
        property_id: String,
        aggregate_json: String,
    ) -> Result<String, ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let prop_uuid = parse_uuid(&property_id)?;
        let agregat: Agregat = parse_json(&aggregate_json)?;
        let valeur = database_use_cases::column_aggregate(&self.dbs, db_uuid, prop_uuid, agregat)
            .map_err(ChaqaqError::from)?;
        to_json(&valeur)
    }

    pub fn search_database_entries_json(
        &self,
        db_id: String,
        query: String,
    ) -> Result<String, ChaqaqError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entrees = database_use_cases::search_entries(&self.dbs, db_uuid, &query)
            .map_err(ChaqaqError::from)?;
        to_json(&entrees)
    }
}
