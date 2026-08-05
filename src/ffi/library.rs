//! Cross-domain library operations on the [`PinkhaApi`] facade.

use crate::application::use_cases;

use super::types::{
    BlockSearchHitFfi, SuperSearchResultsFfi, book_meta_to_ffi, leaf_meta_to_ffi, shelf_meta_to_ffi,
};
use super::types::BulkOutcomeFfi;
use super::validation::{parse_uuids, validate_string};
use super::{PinkhaApi, PinkhaError};

impl PinkhaApi {
    /// Runs every search axis in a single call: leaf titles, block
    /// content (with snippets), book titles and shelf names. The
    /// leaf axis is deduplicated in Rust — a doc matching both title
    /// and content surfaces once in the title hits.
    pub fn super_search(&self, query: String) -> Result<SuperSearchResultsFfi, PinkhaError> {
        validate_string(&query, "query")?;
        let results = use_cases::super_search(&self.uow(), &query).map_err(PinkhaError::from)?;
        Ok(SuperSearchResultsFfi {
            leaves_by_title: results
                .leaves_by_title
                .into_iter()
                .map(leaf_meta_to_ffi)
                .collect(),
            leaves_by_content: results
                .leaves_by_content
                .into_iter()
                .map(|h| BlockSearchHitFfi {
                    doc: leaf_meta_to_ffi(h.doc),
                    block_id: h.block_id.to_string(),
                    snippet: h.snippet,
                })
                .collect(),
            books: results.books.into_iter().map(book_meta_to_ffi).collect(),
            shelves: results
                .shelves
                .into_iter()
                .map(shelf_meta_to_ffi)
                .collect(),
        })
    }

    /// Permanently purges every soft-deleted leaf, book and shelf
    /// in one bulk operation. Returns the total number of items removed.
    pub fn empty_trash(&self) -> Result<u32, PinkhaError> {
        use_cases::empty_trash(&self.uow()).map_err(PinkhaError::from)
    }

    /// Soft-deletes a mixed selection in a single call.
    ///
    /// Swift used to loop over the selection, paying one FFI crossing and
    /// one full library reload per item for what the user performed as a
    /// single tap. Ids that no longer exist are counted as `skipped`
    /// rather than failing the batch — a selection is a snapshot taken
    /// before the confirmation dialog, so it can go stale legitimately.
    pub fn delete_items(
        &self,
        leaf_ids: Vec<String>,
        book_ids: Vec<String>,
        shelf_ids: Vec<String>,
    ) -> Result<BulkOutcomeFfi, PinkhaError> {
        let (l, b, s) = (
            parse_uuids(leaf_ids)?,
            parse_uuids(book_ids)?,
            parse_uuids(shelf_ids)?,
        );
        let out = use_cases::delete_items(&self.uow(), &l, &b, &s).map_err(PinkhaError::from)?;
        Ok(BulkOutcomeFfi {
            affected: out.affected,
            skipped: out.skipped,
        })
    }

    /// Restores a mixed selection out of Compost. See [`Self::delete_items`].
    pub fn restore_items(
        &self,
        leaf_ids: Vec<String>,
        book_ids: Vec<String>,
        shelf_ids: Vec<String>,
    ) -> Result<BulkOutcomeFfi, PinkhaError> {
        let (l, b, s) = (
            parse_uuids(leaf_ids)?,
            parse_uuids(book_ids)?,
            parse_uuids(shelf_ids)?,
        );
        let out = use_cases::restore_items(&self.uow(), &l, &b, &s).map_err(PinkhaError::from)?;
        Ok(BulkOutcomeFfi {
            affected: out.affected,
            skipped: out.skipped,
        })
    }

    /// Permanently removes a mixed selection. See [`Self::delete_items`].
    pub fn purge_items(
        &self,
        leaf_ids: Vec<String>,
        book_ids: Vec<String>,
        shelf_ids: Vec<String>,
    ) -> Result<BulkOutcomeFfi, PinkhaError> {
        let (l, b, s) = (
            parse_uuids(leaf_ids)?,
            parse_uuids(book_ids)?,
            parse_uuids(shelf_ids)?,
        );
        let out = use_cases::purge_items(&self.uow(), &l, &b, &s).map_err(PinkhaError::from)?;
        Ok(BulkOutcomeFfi {
            affected: out.affected,
            skipped: out.skipped,
        })
    }
}
