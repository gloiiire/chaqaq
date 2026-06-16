pub mod application;
pub mod domain;
pub mod extractors;
pub mod ffi;
pub mod infrastructure;

pub use ffi::{
    BlockSearchHitFfi, BookMetaFfi, LeafMetaFfi, ShelfMetaFfi, ImportResultFfi,
    NotionDatabaseSummaryFfi, PinkhaApi, PinkhaError, SuperSearchResultsFfi,
};

uniffi::include_scaffolding!("pinkha");
