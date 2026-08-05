pub mod application;
pub mod domain;
pub mod extractors;
pub mod ffi;
pub mod infrastructure;

pub use ffi::{
    BlockSearchHitFfi, BookMetaFfi, BulkOutcomeFfi, ImportResultFfi, LeafMetaFfi,
    LibrarySnapshotFfi, NotionDatabaseSummaryFfi, NotionPageSummaryFfi, PinkhaApi, PinkhaError,
    ShelfMetaFfi, SuperSearchResultsFfi,
};

uniffi::include_scaffolding!("pinkha");
