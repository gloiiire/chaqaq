pub mod application;
pub mod domain;
pub mod ffi;
pub mod infrastructure;

pub use ffi::{ChaqaqApi, ChaqaqError, DatabaseMetaFfi, DocumentMetaFfi};

uniffi::include_scaffolding!("chaqaq");
