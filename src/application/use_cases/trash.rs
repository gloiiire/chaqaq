//! Cross-domain trash operations spanning leaves, books and shelves.

use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::application::use_cases as leaf_use_cases;
use crate::application::{book_use_cases, shelf_use_cases};

/// Permanently purges every soft-deleted leaf, book and shelf.
/// Returns the total number of items removed.
pub fn empty_trash(uow: &dyn UnitOfWork) -> Result<u32, PinkhaError> {
    let docs = leaf_use_cases::list_deleted_leaves(uow)?;
    let dbs = book_use_cases::list_deleted_books(uow)?;
    let shelves = shelf_use_cases::list_deleted_shelves(uow)?;

    for meta in &docs {
        leaf_use_cases::purge_leaf(uow, meta.id)?;
    }
    for meta in &dbs {
        book_use_cases::purge_book(uow, meta.id)?;
    }
    for meta in &shelves {
        shelf_use_cases::purge_shelf(uow, meta.id)?;
    }

    Ok((docs.len() + dbs.len() + shelves.len()) as u32)
}
