pub mod application;
pub mod domain;
pub mod extractors;
pub mod ffi;
pub mod infrastructure;

pub use ffi::{PinkhaApi, PinkhaError, DatabaseMetaFfi, DocumentMetaFfi};

uniffi::include_scaffolding!("pinkha");
