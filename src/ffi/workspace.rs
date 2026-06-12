//! Cross-domain workspace operations on the [`PinkhaApi`] facade.

use crate::application::use_cases;

use super::types::{
    BlockSearchHitFfi, SuperSearchResultsFfi, db_meta_to_ffi, doc_meta_to_ffi, folder_meta_to_ffi,
};
use super::validation::validate_string;
use super::{PinkhaApi, PinkhaError};

impl PinkhaApi {
    /// Runs every search axis in a single call: document titles, block
    /// content (with snippets), database titles and folder names. The
    /// document axis is deduplicated in Rust — a doc matching both title
    /// and content surfaces once in the title hits.
    pub fn super_search(&self, query: String) -> Result<SuperSearchResultsFfi, PinkhaError> {
        validate_string(&query, "query")?;
        let results = use_cases::super_search(&self.uow(), &query).map_err(PinkhaError::from)?;
        Ok(SuperSearchResultsFfi {
            documents_by_title: results
                .documents_by_title
                .into_iter()
                .map(doc_meta_to_ffi)
                .collect(),
            documents_by_content: results
                .documents_by_content
                .into_iter()
                .map(|h| BlockSearchHitFfi {
                    doc: doc_meta_to_ffi(h.doc),
                    block_id: h.block_id.to_string(),
                    snippet: h.snippet,
                })
                .collect(),
            databases: results.databases.into_iter().map(db_meta_to_ffi).collect(),
            folders: results
                .folders
                .into_iter()
                .map(folder_meta_to_ffi)
                .collect(),
        })
    }

    /// Permanently purges every soft-deleted document, database and folder
    /// in one bulk operation. Returns the total number of items removed.
    pub fn empty_trash(&self) -> Result<u32, PinkhaError> {
        use_cases::empty_trash(&self.uow()).map_err(PinkhaError::from)
    }
}
