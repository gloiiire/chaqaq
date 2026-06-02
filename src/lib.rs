pub mod application;
pub mod domain;
pub mod extractors;
pub mod ffi;
pub mod infrastructure;

pub use ffi::{
    DatabaseMetaFfi, DocumentMetaFfi, FolderMetaFfi, ImportResultFfi, NotionDatabaseSummaryFfi,
    PinkhaApi, PinkhaError,
};

uniffi::include_scaffolding!("pinkha");
