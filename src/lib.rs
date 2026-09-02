// Clippy juge le code que GÉNÈRE UniFFI, pas seulement le nôtre :
// `uniffi::include_scaffolding!` en bas de ce fichier aspire
// `pinkha.uniffi.rs` dans notre crate. Toute règle qui s'y déclenche fait
// échouer `-D warnings` sur du code que nous n'écrivons pas et ne pouvons pas
// corriger.
//
// `large_const_arrays` s'est mise à mordre avec Rust 1.98 sur le runner CI —
// la machine de dev est en 1.96, d'où un lint vert en local et rouge en CI.
// Le tampon de métadonnées incriminé grandit avec le `.udl`, donc le
// problème ne fera que revenir.
//
// Porté au niveau du crate faute de mieux : on ne peut pas annoter une ligne
// d'un fichier généré. La portée reste étroite (une seule règle) et le code
// que nous écrivons, lui, ne définit aucun grand tableau constant.
#![allow(clippy::large_const_arrays)]

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
