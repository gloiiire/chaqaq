pub mod application;
pub mod domain;
pub mod extractors;
pub mod ffi;
pub mod infrastructure;

pub use ffi::{
    BlockSearchHitFfi, BookMetaFfi, BulkOutcomeFfi, LeafMetaFfi, ShelfMetaFfi, ImportResultFfi,
    NotionDatabaseSummaryFfi, NotionPageSummaryFfi, PinkhaApi, PinkhaError,
    SuperSearchResultsFfi,
};

uniffi::include_scaffolding!("pinkha");
