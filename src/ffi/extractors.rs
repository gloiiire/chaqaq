//! Import endpoints — one per source application — on the [`PinkhaApi`] facade.
//!
//! OAuth2 token exchange happens in Swift before calling these methods;
//! Rust only receives the final bearer token.

use std::sync::OnceLock;

use crate::extractors::{ExtractorError, ImportResult};

use super::types::{ImportResultFfi, NotionDatabaseSummaryFfi};
use super::validation::validate_string;
use super::{PinkhaApi, PinkhaError};

/// Process-wide multi-threaded Tokio runtime used to drive `reqwest`-based
/// extractors from a non-async UniFFI entry point.
///
/// UniFFI 0.31 ships its own foreign-task executor, which is not a Tokio
/// runtime. Polling a `reqwest` future under that executor panics with
/// "there is no reactor running" because reqwest registers I/O with Tokio
/// directly. We sidestep this by exposing the import endpoints as synchronous
/// FFI methods and `block_on`-ing the extractor future on this runtime.
fn tokio_runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .thread_name("pinkha-tokio")
            .build()
            .expect("failed to build Tokio runtime for pinkha extractors")
    })
}

impl PinkhaApi {
    /// Asks the in-flight import to stop. The import loop rolls back
    /// everything it created (documents + database) and the import call
    /// returns an "import cancelled" error. No-op when nothing is running.
    pub fn cancel_import(&self) {
        crate::extractors::cancel::request();
    }

    // ── Extractors ────────────────────────────────────────────────────────────
    //
    // Async import methods — one per source application.
    // Each method creates the appropriate extractor and delegates to its `run`.
    //
    // UDL: mark with [Async][Throws=PinkhaError] when wiring up each extractor.
    // OAuth2 token exchange happens in Swift before calling these methods;
    // Rust only receives the final bearer token.

    /// Imports a Notion database into Pinkha.
    ///
    /// `token`       — Notion bearer token (OAuth2 or private integration token).
    /// `database_id` — 32-char hex ID or full Notion URL of the database.
    ///
    /// Synchronous on the FFI boundary: the extractor uses `reqwest`, which
    /// needs a Tokio reactor, and UniFFI's foreign-task executor doesn't
    /// provide one. We block on the process-wide Tokio runtime so callers must
    /// dispatch this method off the main thread themselves (e.g. via Swift's
    /// `Task.detached`). See [`tokio_runtime`] for the rationale.
    /// Lists every Notion database the OAuth token can see — used by the
    /// picker UI so the user can multi-select databases to import without
    /// copy-pasting URLs. Sync for the same Tokio-reactor reason as
    /// `import_from_notion` (cf. [`tokio_runtime`]).
    pub fn list_notion_databases(
        &self,
        token: String,
    ) -> Result<Vec<NotionDatabaseSummaryFfi>, PinkhaError> {
        validate_string(&token, "token")?;
        let summaries = tokio_runtime()
            .block_on(crate::extractors::notion::list_databases(&token))
            .map_err(Self::map_notion_picker_error)?;
        Ok(summaries
            .into_iter()
            .map(|s| NotionDatabaseSummaryFfi {
                id: s.id,
                title: s.title,
                icon_emoji: s.icon_emoji,
                last_edited: s.last_edited,
            })
            .collect())
    }

    /// Same surface as [`list_notion_databases`] but uses the
    /// 2025-09-03 data-source-aware path under the hood. Pickers
    /// should prefer this version — multi-source DBs that the
    /// legacy `object: database` filter misses come back in. The
    /// legacy method stays available so callers that need the
    /// strict 2022 contract can still opt into it.
    pub fn list_notion_databases_v2025(
        &self,
        token: String,
    ) -> Result<Vec<NotionDatabaseSummaryFfi>, PinkhaError> {
        validate_string(&token, "token")?;
        let summaries = tokio_runtime()
            .block_on(crate::extractors::notion::list_databases_v2025(&token))
            .map_err(Self::map_notion_picker_error)?;
        Ok(summaries
            .into_iter()
            .map(|s| NotionDatabaseSummaryFfi {
                id: s.id,
                title: s.title,
                icon_emoji: s.icon_emoji,
                last_edited: s.last_edited,
            })
            .collect())
    }

    /// Shared `ExtractorError → PinkhaError` mapping for the Notion
    /// picker paths. Inline duplication of this match-arm pyramid
    /// between two callers was begging to drift apart.
    fn map_notion_picker_error(e: crate::extractors::ExtractorError) -> PinkhaError {
        match e {
            crate::extractors::ExtractorError::Http { status, message } => PinkhaError::Storage {
                detail: format!("Notion HTTP {status}: {message}"),
            },
            crate::extractors::ExtractorError::Auth(msg) => {
                PinkhaError::InvalidOperation { detail: msg }
            }
            crate::extractors::ExtractorError::Parse(msg) => PinkhaError::Storage { detail: msg },
            crate::extractors::ExtractorError::Storage(e) => e.into(),
            ExtractorError::Cancelled => PinkhaError::InvalidOperation {
                detail: "import cancelled".to_string(),
            },
        }
    }

    pub fn import_from_notion(
        &self,
        token: String,
        database_id: String,
        covers_dir: Option<String>,
    ) -> Result<ImportResultFfi, PinkhaError> {
        use crate::extractors::notion::{NotionConfig, NotionExtractor};
        use crate::extractors::traits::Extractor;
        validate_string(&token, "token")?;
        validate_string(&database_id, "database_id")?;
        if let Some(dir) = covers_dir.as_deref() {
            validate_string(dir, "covers_dir")?;
        }
        let extractor = NotionExtractor::new();
        let config = NotionConfig {
            token,
            database_id,
            covers_dir,
        };
        tokio_runtime()
            .block_on(extractor.run(
                config,
                &self.docs
                    as &(dyn crate::application::repository::DocumentRepository + Send + Sync),
                &self.dbs
                    as &(
                         dyn crate::application::database_repository::DatabaseRepository
                             + Send
                             + Sync
                     ),
                &self.folders,
            ))
            .map(ffi_import_result)
            .map_err(|e| match e {
                crate::extractors::ExtractorError::Http { status, message } => {
                    PinkhaError::Storage {
                        detail: format!("Notion HTTP {status}: {message}"),
                    }
                }
                crate::extractors::ExtractorError::Auth(msg) => {
                    PinkhaError::InvalidOperation { detail: msg }
                }
                crate::extractors::ExtractorError::Parse(msg) => {
                    PinkhaError::Storage { detail: msg }
                }
                crate::extractors::ExtractorError::Storage(e) => e.into(),
                ExtractorError::Cancelled => PinkhaError::InvalidOperation {
                    detail: "import cancelled".to_string(),
                },
            })
    }

    /// Imports notes from Bear's local SQLite database into Pinkha documents.
    ///
    /// `db_path` — absolute path to Bear's `database.sqlite`, obtained via a
    /// Swift file picker scoped to Bear's group container.
    pub async fn import_from_bear(&self, db_path: String) -> Result<ImportResultFfi, PinkhaError> {
        use crate::extractors::bear::{BearConfig, BearExtractor};
        use crate::extractors::traits::Extractor;
        validate_string(&db_path, "db_path")?;
        let extractor = BearExtractor::new();
        let config = BearConfig { db_path };
        extractor
            .run(config, &self.docs, &self.dbs, &self.folders)
            .await
            .map(ffi_import_result)
            .map_err(extractor_err_to_ffi)
    }

    /// Imports pages from Craft's local `.realm` file into Pinkha documents.
    ///
    /// `db_path` — absolute path to a `*.realm` file inside Craft's container,
    /// obtained via a Swift file picker.  Pinkha reads it in read-only mode.
    pub async fn import_from_craft(&self, db_path: String) -> Result<ImportResultFfi, PinkhaError> {
        use crate::extractors::craft::{CraftConfig, CraftExtractor};
        use crate::extractors::traits::Extractor;
        validate_string(&db_path, "db_path")?;
        let extractor = CraftExtractor::new();
        let config = CraftConfig { db_path };
        extractor
            .run(config, &self.docs, &self.dbs, &self.folders)
            .await
            .map(ffi_import_result)
            .map_err(extractor_err_to_ffi)
    }

    /// `root_dir` — absolute path to the folder containing `.textbundle` packages
    /// exported from Craft ("Export All").
    pub async fn import_from_craft_textbundle(
        &self,
        root_dir: String,
    ) -> Result<ImportResultFfi, PinkhaError> {
        use crate::extractors::craft_textbundle::{
            CraftTextBundleConfig, CraftTextBundleExtractor,
        };
        use crate::extractors::traits::Extractor;
        validate_string(&root_dir, "root_dir")?;
        let extractor = CraftTextBundleExtractor::new();
        let config = CraftTextBundleConfig { root_dir };
        extractor
            .run(config, &self.docs, &self.dbs, &self.folders)
            .await
            .map(ffi_import_result)
            .map_err(extractor_err_to_ffi)
    }

    /// Combines Craft's `.realm` database with a folder of `.textbundle` exports.
    /// `realm_path` — absolute path to the `.realm` file.
    /// `textbundle_root` — absolute path to the folder containing `.textbundle` packages.
    pub async fn import_from_craft_combined(
        &self,
        realm_path: String,
        textbundle_root: String,
    ) -> Result<ImportResultFfi, PinkhaError> {
        use crate::extractors::craft_combined::{CraftCombinedConfig, CraftCombinedExtractor};
        validate_string(&realm_path, "realm_path")?;
        validate_string(&textbundle_root, "textbundle_root")?;
        let extractor = CraftCombinedExtractor::new();
        let config = CraftCombinedConfig {
            realm_path,
            textbundle_root,
        };
        extractor
            .run_detailed(config, &self.docs, &self.dbs, &self.folders)
            .await
            .map(|(r, bd)| ImportResultFfi {
                app: r.app.to_string(),
                database_id: String::new(),
                documents: r.documents as u32,
                entries: 0,
                blocks: r.blocks as u32,
                skipped: r.skipped as u32,
                matched_textbundle: bd.matched_textbundle as u32,
                realm_fallback: bd.realm_fallback as u32,
                textbundle_only: bd.textbundle_only as u32,
            })
            .map_err(extractor_err_to_ffi)
    }
}

fn ffi_import_result(r: ImportResult) -> ImportResultFfi {
    ImportResultFfi {
        app: r.app.to_string(),
        database_id: r.database_id.map(|id| id.to_string()).unwrap_or_default(),
        documents: r.documents as u32,
        entries: r.entries as u32,
        blocks: r.blocks as u32,
        skipped: r.skipped as u32,
        matched_textbundle: 0,
        realm_fallback: 0,
        textbundle_only: 0,
    }
}

fn extractor_err_to_ffi(e: ExtractorError) -> PinkhaError {
    match e {
        ExtractorError::Http { status, message } => PinkhaError::Storage {
            detail: format!("HTTP {status}: {message}"),
        },
        ExtractorError::Auth(msg) => PinkhaError::InvalidOperation { detail: msg },
        ExtractorError::Parse(msg) => PinkhaError::Storage { detail: msg },
        ExtractorError::Storage(e) => e.into(),
        ExtractorError::Cancelled => PinkhaError::InvalidOperation {
            detail: "import cancelled".to_string(),
        },
    }
}
