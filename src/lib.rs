pub mod application;
pub mod domain;
pub mod extractors;
pub mod ffi;
pub mod infrastructure;

pub use ffi::{PinkhaApi, PinkhaError, DatabaseMetaFfi, DocumentMetaFfi, FolderMetaFfi, ImportResultFfi};

uniffi::include_scaffolding!("pinkha");
