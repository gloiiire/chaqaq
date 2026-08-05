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

/// Outcome of a bulk lifecycle operation: how many items were affected,
/// and how many ids were skipped because they no longer exist.
///
/// Missing ids are not an error. A bulk selection is a snapshot of the UI
/// taken before the user confirmed, so an id can legitimately have been
/// removed in between (a cascade delete from a book, a second device).
/// Failing the whole batch for one stale id would strand the other ninety-
/// nine, so they are counted and reported instead.
pub struct BulkOutcome {
    pub affected: u32,
    pub skipped: u32,
}

/// Applies `op` to every id, tolerating `NotFound` and propagating anything
/// else. Shared by the three bulk entry points below.
fn apply_tolerating_missing<F>(ids: &[uuid::Uuid], mut op: F) -> Result<(u32, u32), PinkhaError>
where
    F: FnMut(uuid::Uuid) -> Result<(), PinkhaError>,
{
    let mut affected = 0;
    let mut skipped = 0;
    for &id in ids {
        match op(id) {
            Ok(()) => affected += 1,
            Err(PinkhaError::NotFound(_)) => skipped += 1,
            Err(e) => return Err(e),
        }
    }
    Ok((affected, skipped))
}

/// Soft-deletes a mixed batch of leaves, books and shelves in one call.
///
/// The UI used to loop in Swift, which meant one FFI crossing *and* one full
/// library reload per selected item — quadratic-feeling work for what the
/// user experiences as a single "Delete (100)" tap.
pub fn delete_items(
    uow: &dyn UnitOfWork,
    leaf_ids: &[uuid::Uuid],
    book_ids: &[uuid::Uuid],
    shelf_ids: &[uuid::Uuid],
) -> Result<BulkOutcome, PinkhaError> {
    let (a1, s1) = apply_tolerating_missing(leaf_ids, |id| leaf_use_cases::delete_leaf(uow, id))?;
    let (a2, s2) = apply_tolerating_missing(book_ids, |id| book_use_cases::delete_book(uow, id))?;
    let (a3, s3) = apply_tolerating_missing(shelf_ids, |id| shelf_use_cases::delete_shelf(uow, id))?;
    Ok(BulkOutcome {
        affected: a1 + a2 + a3,
        skipped: s1 + s2 + s3,
    })
}

/// Restores a mixed batch out of Compost. Same shape as [`delete_items`].
pub fn restore_items(
    uow: &dyn UnitOfWork,
    leaf_ids: &[uuid::Uuid],
    book_ids: &[uuid::Uuid],
    shelf_ids: &[uuid::Uuid],
) -> Result<BulkOutcome, PinkhaError> {
    let (a1, s1) = apply_tolerating_missing(leaf_ids, |id| leaf_use_cases::restore_leaf(uow, id))?;
    let (a2, s2) = apply_tolerating_missing(book_ids, |id| book_use_cases::restore_book(uow, id))?;
    let (a3, s3) =
        apply_tolerating_missing(shelf_ids, |id| shelf_use_cases::restore_shelf(uow, id))?;
    Ok(BulkOutcome {
        affected: a1 + a2 + a3,
        skipped: s1 + s2 + s3,
    })
}

/// Permanently removes a mixed batch. Same shape as [`delete_items`].
pub fn purge_items(
    uow: &dyn UnitOfWork,
    leaf_ids: &[uuid::Uuid],
    book_ids: &[uuid::Uuid],
    shelf_ids: &[uuid::Uuid],
) -> Result<BulkOutcome, PinkhaError> {
    let (a1, s1) = apply_tolerating_missing(leaf_ids, |id| leaf_use_cases::purge_leaf(uow, id))?;
    let (a2, s2) = apply_tolerating_missing(book_ids, |id| book_use_cases::purge_book(uow, id))?;
    let (a3, s3) = apply_tolerating_missing(shelf_ids, |id| shelf_use_cases::purge_shelf(uow, id))?;
    Ok(BulkOutcome {
        affected: a1 + a2 + a3,
        skipped: s1 + s2 + s3,
    })
}
