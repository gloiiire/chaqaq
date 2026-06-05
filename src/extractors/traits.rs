// ── Extractor trait ───────────────────────────────────────────────────────────
//
// Shared contract for all source-app extractors.
//
// Not intended for `dyn` dispatch — use concrete generic bounds (`E: Extractor`)
// or call concrete types directly from the FFI layer.

use super::{ExtractorError, ImportResult};
use crate::application::database_repository::DatabaseRepository;
use crate::application::folder_repository::FolderRepository;
use crate::application::repository::DocumentRepository;

/// Common interface for all import pipelines.
///
/// Each implementor owns the credentials and HTTP client (or file handle) for
/// one source application. The `run` method fetches the remote data, maps it to
/// Pinkha domain types, and persists everything via the provided repositories.
///
/// # Async
/// Implementations are async to support HTTP-based sources (Notion, Craft, …).
/// File-based sources (Bear) can still implement the trait — their futures will
/// simply resolve synchronously after the disk reads.
pub trait Extractor {
    /// Source-specific configuration (e.g. OAuth token + database ID for Notion,
    /// SQLite path for Bear).
    type Config: Send;

    /// Display name of the source application.
    fn app_name(&self) -> &'static str;

    /// Runs the full import pipeline for the given config.
    ///
    /// Implementors should:
    /// 1. Authenticate / open the data source.
    /// 2. Fetch schema + content (with pagination if needed).
    /// 3. Map every source type to a Pinkha domain type.
    /// 4. Persist via `docs` and `dbs` — never touch SQLite directly.
    /// 5. Return an [`ImportResult`] summarising what was imported.
    ///
    /// The returned future must be `Send` so it can be driven by the tokio
    /// multi-thread runtime exposed via UniFFI async.
    fn run(
        &self,
        config: Self::Config,
        docs: &(dyn DocumentRepository + Send + Sync),
        dbs: &(dyn DatabaseRepository + Send + Sync),
        folders: &(dyn FolderRepository + Send + Sync),
    ) -> impl std::future::Future<Output = Result<ImportResult, ExtractorError>> + Send;
}
