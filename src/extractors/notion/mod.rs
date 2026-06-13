// ── Notion extractor ──────────────────────────────────────────────────────────
//
// Pipeline: OAuth2 token (obtained by Swift) + database ID
//   → GET /v1/databases/{id}          (schema: properties + title)
//   → POST /v1/databases/{id}/query   (entries, paginated)
//   → GET /v1/blocks/{page_id}/children (block content, paginated)
//   → map → persist via DocumentRepository + DatabaseRepository

mod assets;
pub mod client;
pub mod mapper;
mod mentions;
pub mod schema;

pub use mentions::{normalize_notion_id, rewrite_notion_mentions, rewrite_notion_mentions_logged};

use self::assets::{download_cover, download_or_keep_icon, notion_icon_identifier};

use std::collections::HashMap;
use std::sync::Mutex;

use futures_util::{StreamExt, stream};

use uuid::Uuid;

use crate::application::database_repository::DatabaseRepository;
use crate::application::database_use_cases;
use crate::application::folder_repository::FolderRepository;
use crate::application::repository::DocumentRepository;
use crate::application::use_cases;
use crate::domain::database::{PAGE_LINK_PROPERTY, Property, PropertyType, PropertyValue};
use crate::domain::document::InlineText;
use crate::extractors::traits::Extractor;
use crate::extractors::{ExtractorError, ImportResult};
use crate::infrastructure::no_op_unit_of_work::NoOpUnitOfWork;

/// How many pages have their content fetched concurrently during an
/// import. The Notion API allows ~3 requests/second on average — a wider
/// window only produces 429s that the retry/backoff then sleeps through,
/// cancelling the gain.
const IMPORT_CONCURRENCY: usize = 3;

use self::client::NotionClient;
use self::mapper::{
    extract_database_id, map_block, map_block_color, map_property_type, map_property_value,
};
use self::schema::NotionPagePropValue;

// ── Config ────────────────────────────────────────────────────────────────────

/// Input required to run a Notion import.
///
/// `token` is a bearer token — either an OAuth2 access token obtained via the
/// public integration flow or a private integration token (`secret_xxx`).
/// Swift handles the OAuth2 browser dance; Rust only receives the final token.
pub struct NotionConfig {
    /// Bearer token for the Notion API.
    pub token: String,
    /// ID (32-char hex) or URL of the Notion database to import.
    pub database_id: String,
    /// Absolute path to an existing directory where page covers will be
    /// downloaded. When `None`, covers are stored as their original URL —
    /// fine for external covers, but Notion-hosted ones expire after ~1h.
    pub covers_dir: Option<String>,
}

// ── Extractor ─────────────────────────────────────────────────────────────────

pub struct NotionExtractor;

impl NotionExtractor {
    pub fn new() -> Self {
        Self
    }
}

/// Public summary of a Notion database, returned by [`list_databases`] for
/// the picker UI. Plain title and emoji-or-`None` icon — no rich text
/// gymnastics for the caller, the renderer just slots them into a row.
pub struct NotionDatabaseSummary {
    /// 32-char hex ID (dashed UUID format, matches how `import_from_notion`
    /// expects to receive it).
    pub id: String,
    /// Concatenated plain-text title runs. Empty string when the database
    /// has no title.
    pub title: String,
    /// Emoji icon if any (`"📚"`). Image icons aren't yet surfaced — the
    /// picker falls back to a generic database icon when this is `None`.
    pub icon_emoji: Option<String>,
    /// ISO 8601 last-edited timestamp from Notion (`"2026-06-01T…"`). The
    /// picker sorts recent-first; an empty string sorts to the bottom.
    pub last_edited: String,
}

/// Lists every Notion database the supplied OAuth token can see. Used by the
/// Swift picker so the user no longer needs to copy-paste each database URL.
pub async fn list_databases(token: &str) -> Result<Vec<NotionDatabaseSummary>, ExtractorError> {
    let client = NotionClient::new(token)?;
    let hits = client.list_accessible_databases().await?;
    let mut summaries: Vec<NotionDatabaseSummary> = hits
        .into_iter()
        .map(|hit| {
            let title: String = hit
                .title
                .iter()
                .map(|run| run.plain_text.as_str())
                .collect();
            let icon_emoji = match hit.icon {
                Some(schema::NotionPageIcon::Emoji { emoji }) => Some(emoji),
                _ => None,
            };
            NotionDatabaseSummary {
                id: hit.id,
                title,
                icon_emoji,
                last_edited: hit.last_edited_time,
            }
        })
        .collect();
    // Recent-first ordering by ISO 8601 timestamp — string comparison works
    // because the format is fixed-width with leading zeros.
    summaries.sort_by(|a, b| b.last_edited.cmp(&a.last_edited));
    Ok(summaries)
}

/// 2025-09-03 picker path : merges the legacy `object: database` search
/// with the new `object: data_source` search so multi-source databases
/// that the legacy filter misses come back in.
///
/// Strategy :
///   1. Call the legacy `list_accessible_databases` — captures every
///      DB created under the old contract.
///   2. Call the new `list_accessible_data_sources` (per-request
///      `Notion-Version: 2025-09-03` header).
///   3. For each data source, derive its wrapping database id from
///      `parent.database_id`. Add to the union only if the legacy
///      pass didn't already pick it up — legacy wins on dupes
///      because its `title` is richer (rich-text vs plain string).
///
/// The returned `id`s are always database UUIDs, which keeps the
/// existing legacy `import_from_notion` flow usable as-is. SOLID :
/// extend, don't modify ; the original `list_databases` is left
/// untouched for any caller that wants the strict legacy behaviour.
pub async fn list_databases_v2025(
    token: &str,
) -> Result<Vec<NotionDatabaseSummary>, ExtractorError> {
    let client = NotionClient::new(token)?;

    let mut by_id: std::collections::HashMap<String, NotionDatabaseSummary> =
        std::collections::HashMap::new();

    // ── 1. Legacy database hits ──────────────────────────────────────────
    for hit in client.list_accessible_databases().await? {
        let title: String = hit
            .title
            .iter()
            .map(|run| run.plain_text.as_str())
            .collect();
        let icon_emoji = match hit.icon {
            Some(schema::NotionPageIcon::Emoji { emoji }) => Some(emoji),
            _ => None,
        };
        by_id.insert(
            hit.id.clone(),
            NotionDatabaseSummary {
                id: hit.id,
                title,
                icon_emoji,
                last_edited: hit.last_edited_time,
            },
        );
    }

    // ── 2. v2025 data source hits — best-effort, soft-fail ──────────────
    // We tolerate a Notion outage / unexpected response on the new
    // endpoint and still return the legacy results. The user sees no
    // worse than the original picker if the v2025 call fails.
    if let Ok(data_sources) = client.list_accessible_data_sources().await {
        for ds in data_sources {
            let database_id = match ds.parent {
                schema::NotionDataSourceParent::DatabaseId { database_id } => database_id,
                schema::NotionDataSourceParent::Unknown => continue,
            };
            if by_id.contains_key(&database_id) {
                continue;
            }
            let icon_emoji = match ds.icon {
                Some(schema::NotionPageIcon::Emoji { emoji }) => Some(emoji),
                _ => None,
            };
            by_id.insert(
                database_id.clone(),
                NotionDatabaseSummary {
                    id: database_id,
                    title: ds.name,
                    icon_emoji,
                    last_edited: ds.last_edited_time,
                },
            );
        }
    }

    // ── 3. Walk accessible pages for `child_database` blocks ────────────
    // Notion's `object: database` search doesn't recurse into pages
    // — it only returns top-level databases the integration was
    // granted direct access to. DBs created as `child_database`
    // blocks inside a shared page never appear. We close the gap by
    // listing every accessible page and walking its block tree.
    if let Ok(pages) = client.list_accessible_pages().await {
        for page in pages {
            if let Ok(child_dbs) = client.list_child_databases_in_page(&page.id).await {
                for (db_id, title) in child_dbs {
                    if by_id.contains_key(&db_id) {
                        continue;
                    }
                    by_id.insert(
                        db_id.clone(),
                        NotionDatabaseSummary {
                            id: db_id,
                            title,
                            icon_emoji: None,
                            last_edited: page.last_edited_time.clone(),
                        },
                    );
                }
            }
        }
    }

    let mut summaries: Vec<NotionDatabaseSummary> = by_id.into_values().collect();
    summaries.sort_by(|a, b| b.last_edited.cmp(&a.last_edited));
    Ok(summaries)
}

impl Default for NotionExtractor {
    fn default() -> Self {
        Self::new()
    }
}

impl Extractor for NotionExtractor {
    type Config = NotionConfig;

    fn app_name(&self) -> &'static str {
        "Notion"
    }

    async fn run(
        &self,
        config: NotionConfig,
        docs: &(dyn DocumentRepository + Send + Sync),
        dbs: &(dyn DatabaseRepository + Send + Sync),
        _folders: &(dyn FolderRepository + Send + Sync),
    ) -> Result<ImportResult, ExtractorError> {
        // 1. Normalise the database ID.
        // A cancel requested after a previous run must not kill this one.
        crate::extractors::cancel::reset();

        let db_id = extract_database_id(&config.database_id);

        // 2. Build the HTTP client.
        let client = NotionClient::new(&config.token)?;

        // 3. Fetch the database schema.
        let schema = client.get_database(&db_id).await?;
        let db_title = schema.title_plain();

        // 4. Build the full property list for the Pinkha database.
        //
        //    Two synthetic properties are always added first:
        //      - "__pinkha_page__" (Text)  — Pinkha document UUID for back-linking
        //      - "Name" (Title)            — the Notion page title
        //
        //    Then all Notion properties (except the built-in "title" type, which
        //    we already handle through the "Name" column) are appended.

        let page_prop = Property::new(PAGE_LINK_PROPERTY, PropertyType::Text);
        let page_prop_id: Uuid = page_prop.id;

        let name_prop = Property::new("Name", PropertyType::Title);
        let name_prop_id: Uuid = name_prop.id;

        let mut all_properties: Vec<Property> = vec![page_prop, name_prop];

        // Map from Notion property name → Pinkha property UUID.
        let mut prop_map: HashMap<String, Uuid> = HashMap::new();

        for (notion_name, def) in &schema.properties {
            // Skip the built-in title column — it is handled via "Name" above.
            if def.type_ == "title" {
                continue;
            }
            let pinkha_type = map_property_type(def);
            let prop = Property::new(notion_name.clone(), pinkha_type);
            prop_map.insert(notion_name.clone(), prop.id);
            all_properties.push(prop);
        }

        // 5. Create the Pinkha database with all properties at once.
        let title_inlines = vec![InlineText {
            content: db_title,
            styles: vec![],
        }];
        let pinkha_db = {
            let uow = NoOpUnitOfWork::with_docs_dbs(docs, dbs);
            database_use_cases::create_database(&uow, title_inlines, all_properties)?
        };
        let pinkha_db_id = pinkha_db.id;

        // 5b. Carry over the Notion-side cover / icon / description so
        // the imported database opens with the same hero the user
        // configured in Notion. Each field is optional and is only
        // applied when present — silent no-ops for databases without
        // a banner or icon.
        {
            let uow = NoOpUnitOfWork::with_docs_dbs(docs, dbs);
            if let Some(cover_url) = schema.cover.as_ref().and_then(|c| c.url()) {
                let _ = database_use_cases::update_database_cover(
                    &uow,
                    pinkha_db_id,
                    Some(cover_url.to_string()),
                );
            }
            if let Some(icon_value) = schema.icon.as_ref().and_then(notion_icon_identifier) {
                let _ =
                    database_use_cases::update_database_icon(&uow, pinkha_db_id, Some(icon_value));
            }
            if !schema.description.is_empty() {
                let desc = schema
                    .description
                    .iter()
                    .map(|r| InlineText {
                        content: r.plain_text.clone(),
                        styles: vec![],
                    })
                    .collect::<Vec<_>>();
                let _ = database_use_cases::update_database_description(&uow, pinkha_db_id, desc);
            }
            // Imported databases land locked by default — Notion data
            // is read-only state we don't want to accidentally edit
            // before the user has reviewed the import. They can flip
            // the lock off from the DB header lock button.
            let _ = database_use_cases::update_database_locked(&uow, pinkha_db_id, true);
        }

        // 6. Paginate through all Notion pages (rows) and import each one.
        let mut total_documents: usize = 0;
        let mut total_entries: usize = 0;
        let mut total_blocks: usize = 0;
        let mut total_skipped: usize = 0;

        // Built incrementally as pages are imported. Used in step 7 to rewrite
        // `[label](https://notion.so/...{notion_id})` links so they point to
        // the matching Pinkha document instead of staying broken Notion URLs.
        // Behind a `Mutex` because concurrent page fetches materialise child
        // pages (and register them here) in parallel.
        let notion_to_pinkha: Mutex<HashMap<String, Uuid>> = Mutex::new(HashMap::new());

        let mut cursor: Option<String> = None;

        loop {
            let response = client.query_database(&db_id, cursor.as_deref()).await?;

            // Fetch page content (blocks, covers, icons) for up to
            // IMPORT_CONCURRENCY pages at a time. `buffered` yields the
            // results in submission order, so the sequential entry
            // insertions below keep the database rows in Notion's order
            // AND avoid concurrent load-modify-write cycles on the
            // database JSON blob (`add_entry_with_document` reads the
            // whole database, pushes a row, and saves it back — racing
            // two of those would drop rows).
            // Materialised into a Vec first: `buffered` over an iterator
            // of already-constructed futures sidesteps the higher-ranked
            // lifetime bound rustc can't prove for a closure returning a
            // borrow-carrying future.
            let page_futures: Vec<_> = response
                .results
                .iter()
                .map(|page| {
                    import_page(
                        &client,
                        page,
                        name_prop_id,
                        page_prop_id,
                        &prop_map,
                        docs,
                        dbs,
                        config.covers_dir.as_deref(),
                        &notion_to_pinkha,
                    )
                })
                .collect();
            let mut imported = stream::iter(page_futures).buffered(IMPORT_CONCURRENCY);

            while let Some(result) = imported.next().await {
                // Cancellation checkpoint: drop the in-flight futures,
                // purge everything this run created and bail. The
                // map already contains every materialised document
                // (top pages register themselves right after their
                // doc is created) so the rollback is complete.
                if crate::extractors::cancel::requested() {
                    drop(imported);
                    purge_partial_import(docs, dbs, pinkha_db_id, &notion_to_pinkha);
                    return Err(ExtractorError::Cancelled);
                }
                let page = result?;
                {
                    let uow = NoOpUnitOfWork::with_docs_dbs(docs, dbs);
                    database_use_cases::add_entry_with_document(
                        &uow,
                        pinkha_db_id,
                        page.values,
                        page.doc_id,
                    )?;
                }

                // The database row contributes the page itself; nested
                // child_page blocks turn into additional pinkha documents
                // counted here so the import summary stays truthful.
                total_documents += 1 + page.child_doc_count;
                total_entries += 1;
                total_blocks += page.block_count;
                total_skipped += page.skipped_count;
            }
            drop(imported);

            if !response.has_more {
                break;
            }
            cursor = response.next_cursor;
        }

        // Concurrency is over — unwrap the map for the read-only passes.
        let notion_to_pinkha = notion_to_pinkha
            .into_inner()
            .unwrap_or_else(|e| e.into_inner());

        // 7. Second pass: rewrite Notion page-link URLs to internal
        //    `pinkha://doc/{uuid}` links now that we know every Notion page's
        //    Pinkha equivalent. Done at the very end because mentions can
        //    point to pages later in the same database — we need the full
        //    map before rewriting any document.
        for pinkha_doc_id in notion_to_pinkha.values() {
            rewrite_notion_mentions_logged(
                docs,
                *pinkha_doc_id,
                &notion_to_pinkha,
                config.covers_dir.as_deref(),
            )?;
        }

        // 8. Publish-date source auto-adoption: when the Notion schema
        //    carries a Date column whose name marks it as the publish
        //    date (e.g. "Publication"), adopt it so every imported row
        //    (and its backing document) sorts by its true date instead
        //    of the import timestamp. Best-effort — a failure here must
        //    not fail an otherwise complete import.
        {
            let uow = NoOpUnitOfWork::with_docs_dbs(docs, dbs);
            if let Ok(db) = database_use_cases::get_database(&uow, pinkha_db_id)
                && let Some(prop_id) = mapper::detect_publish_source(&db.properties)
            {
                let _ = use_cases::set_published_at_source(&uow, pinkha_db_id, Some(prop_id));
            }
        }

        Ok(ImportResult {
            app: "Notion",
            database_id: Some(pinkha_db_id),
            documents: total_documents,
            entries: total_entries,
            blocks: total_blocks,
            skipped: total_skipped,
        })
    }
}

/// Rolls back a cancelled import: hard-deletes every document the run
/// created (top pages and nested child pages — all registered in
/// `notion_to_pinkha`) plus the freshly created database. Best-effort on
/// purpose — a rollback must never surface an error of its own.
fn purge_partial_import(
    docs: &(dyn DocumentRepository + Send + Sync),
    dbs: &(dyn DatabaseRepository + Send + Sync),
    db_id: Uuid,
    notion_to_pinkha: &Mutex<HashMap<String, Uuid>>,
) {
    let uow = NoOpUnitOfWork::with_docs_dbs(docs, dbs);
    let map = notion_to_pinkha.lock().unwrap_or_else(|e| e.into_inner());
    for doc_id in map.values() {
        // Soft-delete first (purge only touches trashed rows), then purge —
        // a cancelled import should leave no trace, not fill the trash.
        let _ = use_cases::delete_document(&uow, *doc_id);
        let _ = use_cases::purge_document(&uow, *doc_id);
    }
    let _ = database_use_cases::delete_database(&uow, db_id);
    let _ = database_use_cases::purge_database(&uow, db_id);
}

// ── Page import helper ────────────────────────────────────────────────────────

/// Everything `import_page` produced for one Notion page. The entry
/// values are returned (not inserted) so the caller can append database
/// rows sequentially, in order, outside the concurrent fetch window.
struct ImportedPage {
    doc_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
    block_count: usize,
    skipped_count: usize,
    child_doc_count: usize,
}

/// Imports one Notion page: creates a Pinkha document, fetches its
/// blocks, and returns the database-entry values the caller inserts —
/// kept out of this function so the concurrent fetch window never races
/// the database blob's load-modify-write cycle.
#[allow(clippy::too_many_arguments)]
async fn import_page(
    client: &NotionClient,
    page: &schema::NotionPageResult,
    name_prop_id: Uuid,
    page_prop_id: Uuid,
    prop_map: &HashMap<String, Uuid>,
    docs: &(dyn DocumentRepository + Send + Sync),
    dbs: &(dyn DatabaseRepository + Send + Sync),
    covers_dir: Option<&str>,
    notion_to_pinkha: &Mutex<HashMap<String, Uuid>>,
) -> Result<ImportedPage, ExtractorError> {
    // Extract the page title from the "title" property type.
    let plain_title = page
        .properties
        .values()
        .find_map(|v| {
            if let NotionPagePropValue::Title { title } = v {
                Some(
                    title
                        .iter()
                        .map(|r| r.plain_text.as_str())
                        .collect::<String>(),
                )
            } else {
                None
            }
        })
        .unwrap_or_else(|| "Untitled".to_string());

    // Create the Pinkha document, threading Notion's `created_time`
    // through so the imported doc keeps its real creation date in the
    // SQLite row's `created_at` column. Falls back to `now()` (the
    // default `create_document` path) when Notion didn't send a
    // timestamp.
    let uow = NoOpUnitOfWork::with_docs_dbs(docs, dbs);
    let doc = if page.created_time.is_empty() {
        use_cases::create_document(&uow, &plain_title)?
    } else {
        use_cases::create_document_with_created_at(&uow, &plain_title, page.created_time.clone())?
    };
    let doc_id = doc.id;
    // Register the mapping immediately: if the user cancels while this
    // future is still in flight, the rollback walks the map — a document
    // created but not yet registered would leak.
    notion_to_pinkha
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(normalize_notion_id(&page.id), doc_id);

    // Debug log : record the Notion-side timestamp + what we forwarded
    // so we can verify the createdAt round-trip after import.
    if let Some(dir) = covers_dir {
        use std::io::Write;
        let line = format!(
            "[createdAt] page={} title={:?} notion_created_time={:?} doc_id={} doc_created_at={:?}\n",
            page.id, plain_title, page.created_time, doc_id, doc.created_at
        );
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(format!("{dir}/notion-debug.log"))
        {
            let _ = f.write_all(line.as_bytes());
        }
    }

    // Imports default to locked = true so the user reads the extracted
    // content (which they didn't write themselves) before editing it.
    // They can unlock from the toolbar.
    use_cases::update_document_locked(&uow, doc_id, true)?;

    // Carry the Notion cover over to the new Pinkha document. When a covers
    // directory is provided, the image is downloaded and stored locally —
    // critical for Notion-hosted URLs which expire after ~1h. Otherwise we
    // fall back to storing the raw URL (the SwiftUI renderer resolves it
    // via AsyncImage but it'll break once the URL dies).
    if let Some(url) = page.cover.as_ref().and_then(|c| c.url()) {
        let stored = if let Some(dir) = covers_dir {
            download_cover(client, url, dir, doc_id)
                .await
                .unwrap_or_else(|_| url.to_string())
        } else {
            url.to_string()
        };
        use_cases::update_document_cover(&uow, doc_id, Some(stored))?;
    }

    // Icons are independent of covers in Notion (a page can have both, one,
    // or neither). Emojis stay as-is (the renderer prints them directly);
    // URL-shaped icons get downloaded with a `_icon` suffix so they don't
    // collide with the cover file on disk.
    if let Some(icon) = page.icon.as_ref() {
        let stored = match icon {
            schema::NotionPageIcon::Emoji { emoji } => Some(emoji.clone()),
            schema::NotionPageIcon::External { external } => {
                Some(download_or_keep_icon(client, &external.url, covers_dir, doc_id).await)
            }
            schema::NotionPageIcon::File { file } => {
                Some(download_or_keep_icon(client, &file.url, covers_dir, doc_id).await)
            }
            schema::NotionPageIcon::Unknown => None,
        };
        if let Some(value) = stored {
            use_cases::update_document_icon(&uow, doc_id, Some(value))?;
        }
    }

    // Fetch and add all blocks to the document efficiently (bulk in-memory, one save).
    // Child_page blocks encountered along the way materialise as nested
    // pinkha documents linked to this one via `parent_doc_id`.
    let (block_count, skipped_count, child_doc_count) =
        fetch_and_add_blocks(client, &page.id, doc_id, docs, notion_to_pinkha, covers_dir).await?;

    // Build the database entry values.
    let mut values: HashMap<Uuid, PropertyValue> = HashMap::new();

    // Synthetic fields.
    values.insert(
        name_prop_id,
        PropertyValue::Title(vec![InlineText {
            content: plain_title,
            styles: vec![],
        }]),
    );
    values.insert(page_prop_id, PropertyValue::Text(doc_id.to_string()));

    // Notion properties → Pinkha property values.
    for (notion_name, pinkha_id) in prop_map {
        if let Some(notion_val) = page.properties.get(notion_name)
            && let Some(pinkha_val) = map_property_value(notion_val)
        {
            values.insert(*pinkha_id, pinkha_val);
        }
    }

    Ok(ImportedPage {
        doc_id,
        values,
        block_count,
        skipped_count,
        child_doc_count,
    })
}

/// Paginates through a page's block children, fetches nested children
/// recursively, and saves once.
///
/// Returns `(total_block_count, total_skipped_count, child_doc_count)` where
/// the counts are recursive (all levels included). `child_doc_count` is the
/// number of nested pinkha documents materialised from `child_page` blocks
/// encountered anywhere in the tree.
async fn fetch_and_add_blocks(
    client: &NotionClient,
    page_id: &str,
    doc_id: Uuid,
    docs: &(dyn DocumentRepository + Send + Sync),
    notion_to_pinkha: &Mutex<HashMap<String, Uuid>>,
    covers_dir: Option<&str>,
) -> Result<(usize, usize, usize), ExtractorError> {
    let (root_blocks, skipped, child_docs) =
        fetch_blocks_recursive(client, page_id, doc_id, docs, notion_to_pinkha, covers_dir).await?;

    let count = count_blocks_recursive(&root_blocks);

    // Bulk in-memory update: load → extend root blocks → save once.
    let mut doc = docs.load(doc_id)?;
    doc.blocks.extend(root_blocks);
    docs.save(&doc)?;

    Ok((count, skipped, child_docs))
}

/// Recursively fetches all blocks for a given parent ID (page or block).
///
/// `owning_doc_id` is the pinkha document these blocks belong to — used as
/// `parent_doc_id` for any nested `child_page` materialised along the way.
/// `notion_to_pinkha` is grown as new pages are materialised so the post-
/// import link-rewriting pass picks them up too.
///
/// Returns the fully-built `Block` tree, the total number of skipped
/// (unmappable) Notion blocks, and the number of pinkha child documents
/// created — all recursive.
async fn fetch_blocks_recursive(
    client: &NotionClient,
    parent_id: &str,
    owning_doc_id: Uuid,
    docs: &(dyn DocumentRepository + Send + Sync),
    notion_to_pinkha: &Mutex<HashMap<String, Uuid>>,
    covers_dir: Option<&str>,
) -> Result<(Vec<crate::domain::document::Block>, usize, usize), ExtractorError> {
    use crate::domain::document::{Block, BlockContent};

    let mut root_blocks: Vec<Block> = Vec::new();
    let mut total_skipped: usize = 0;
    let mut child_docs_created: usize = 0;
    let mut cursor: Option<String> = None;

    loop {
        let response = client.get_page_blocks(parent_id, cursor.as_deref()).await?;

        for notion_block in &response.results {
            // Trace every block type Notion hands us so we can prove whether
            // the early-match on "child_page" actually fires.
            log_block_type(covers_dir, parent_id, &notion_block.type_);
            // Child-page block — materialise a nested pinkha document and
            // emit a `Page { id }` block in the parent that references it.
            // The child page's own content is fetched immediately so
            // navigation works as soon as the import completes.
            if notion_block.type_ == "child_page" {
                let title = notion_block
                    .child_page
                    .as_ref()
                    .map(|cp| cp.title.clone())
                    .unwrap_or_default();
                let child_id = import_child_page(
                    client,
                    &notion_block.id,
                    &title,
                    owning_doc_id,
                    docs,
                    notion_to_pinkha,
                    covers_dir,
                )
                .await?;
                child_docs_created += 1;
                // The Page block sits where the child_page appeared in the
                // parent's flow — keeps the visual position Notion users
                // expect (e.g. mid-page, not always at the end).
                root_blocks.push(Block {
                    id: uuid::Uuid::new_v4(),
                    content: BlockContent::Page { id: child_id },
                    children: Vec::new(),
                    color: None,
                    background_color: None,
                    text_direction: None,
                });
                continue;
            }

            match map_block(notion_block) {
                Some(content) => {
                    let children = if notion_block.has_children {
                        // Recurse into this block's children. Children inherit
                        // the same `owning_doc_id` because they live inside the
                        // same pinkha document.
                        let (child_blocks, child_skipped, child_doc_subcount) =
                            Box::pin(fetch_blocks_recursive(
                                client,
                                &notion_block.id,
                                owning_doc_id,
                                docs,
                                notion_to_pinkha,
                                covers_dir,
                            ))
                            .await?;
                        total_skipped += child_skipped;
                        child_docs_created += child_doc_subcount;
                        child_blocks
                    } else {
                        Vec::new()
                    };

                    root_blocks.push(Block {
                        id: uuid::Uuid::new_v4(),
                        content,
                        children,
                        color: map_block_color(notion_block),
                        background_color: None,
                        text_direction: None,
                    });
                }
                None => {
                    total_skipped += 1;
                    // Even if the parent block itself is unmappable, its children
                    // are lost — consistent with skipping the whole subtree.
                }
            }
        }

        if !response.has_more {
            break;
        }
        cursor = response.next_cursor;
    }

    Ok((root_blocks, total_skipped, child_docs_created))
}

/// Creates a pinkha document for a Notion `child_page` and fetches its own
/// block tree (which may itself contain further nested pages). Returns the
/// new pinkha document id, ready to be embedded in the parent via a
/// [`BlockContent::Page`] block.
async fn import_child_page(
    client: &NotionClient,
    notion_id: &str,
    title: &str,
    parent_doc_id: Uuid,
    docs: &(dyn DocumentRepository + Send + Sync),
    notion_to_pinkha: &Mutex<HashMap<String, Uuid>>,
    covers_dir: Option<&str>,
) -> Result<Uuid, ExtractorError> {
    use crate::domain::document::{Document, InlineText};

    // Build the child document up front so we have its id before fetching
    // any nested content (a grand-child page that mentions us should rewrite
    // to a known id).
    let mut child = Document::new(vec![InlineText {
        content: title.to_string(),
        styles: Vec::new(),
    }]);
    child.parent_doc_id = Some(parent_doc_id);
    // Imports always default to locked: the user should read the imported
    // content before mutating it. Mirrors `import_page`'s top-level pages.
    child.locked = true;
    let child_id = child.id;
    docs.save(&child)?;
    notion_to_pinkha
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(normalize_notion_id(notion_id), child_id);

    // Fetch the page metadata to recover the icon and cover, which the
    // `child_page` block payload doesn't carry. A failed fetch shouldn't
    // abort the whole import — we just skip the decoration in that case.
    let get_page_result = client.get_page(notion_id).await;
    let log_line = match &get_page_result {
        Ok(meta) => format!(
            "OK '{}' (id={}): icon={:?} cover={}\n",
            title,
            notion_id,
            meta.icon,
            meta.cover.is_some()
        ),
        Err(err) => format!("FAIL '{}' (id={}): {err:?}\n", title, notion_id),
    };
    eprintln!("[notion import] {}", log_line.trim_end());
    if let Some(dir) = covers_dir {
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(format!("{dir}/notion-debug.log"))
        {
            let _ = f.write_all(log_line.as_bytes());
        }
    }
    if let Ok(meta) = get_page_result {
        // Cover: same download path as `import_page` so Notion-hosted
        // covers don't expire on us.
        if let Some(url) = meta.cover.as_ref().and_then(|c| c.url()) {
            let stored = if let Some(dir) = covers_dir {
                download_cover(client, url, dir, child_id)
                    .await
                    .unwrap_or_else(|_| url.to_string())
            } else {
                url.to_string()
            };
            let mut decorated = docs.load(child_id)?;
            decorated.cover = Some(stored);
            docs.save(&decorated)?;
        }
        // Icon: emoji is kept as-is, image icons are downloaded next to
        // the cover (suffixed `_icon`) when a covers_dir is provided.
        if let Some(icon) = meta.icon.as_ref() {
            let stored = match icon {
                schema::NotionPageIcon::Emoji { emoji } => Some(emoji.clone()),
                schema::NotionPageIcon::External { external } => {
                    Some(download_or_keep_icon(client, &external.url, covers_dir, child_id).await)
                }
                schema::NotionPageIcon::File { file } => {
                    Some(download_or_keep_icon(client, &file.url, covers_dir, child_id).await)
                }
                schema::NotionPageIcon::Unknown => None,
            };
            if let Some(value) = stored {
                let mut decorated = docs.load(child_id)?;
                decorated.icon = Some(value);
                docs.save(&decorated)?;
            }
        }
    }

    // Fetch the child's content. The recursion threads through the same
    // `notion_to_pinkha` map so deeper child_pages register too.
    let (child_blocks, _skipped, _grand_child_count) = Box::pin(fetch_blocks_recursive(
        client,
        notion_id,
        child_id,
        docs,
        notion_to_pinkha,
        covers_dir,
    ))
    .await?;

    let mut child = docs.load(child_id)?;
    child.blocks = child_blocks;
    docs.save(&child)?;

    Ok(child_id)
}

/// Diagnostic helper — appends one line per Notion block to a debug log
/// in the covers directory. Used to verify which block types Notion
/// actually returns (in particular whether `child_page` shows up at all
/// from `get_page_blocks`).
fn log_block_type(covers_dir: Option<&str>, parent_id: &str, block_type: &str) {
    eprintln!("[notion blocks] parent={parent_id} type={block_type}");
    if let Some(dir) = covers_dir {
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(format!("{dir}/notion-debug.log"))
        {
            let _ = writeln!(f, "[blocks] parent={parent_id} type={block_type}");
        }
    }
}

/// Counts blocks at all levels of the tree (recursive).
fn count_blocks_recursive(blocks: &[crate::domain::document::Block]) -> usize {
    blocks
        .iter()
        .map(|b| 1 + count_blocks_recursive(&b.children))
        .sum()
}
