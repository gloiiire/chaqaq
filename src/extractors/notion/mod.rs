// ── Notion extractor ──────────────────────────────────────────────────────────
//
// Pipeline: OAuth2 token (obtained by Swift) + database ID
//   → GET /v1/databases/{id}          (schema: properties + title)
//   → POST /v1/databases/{id}/query   (entries, paginated)
//   → GET /v1/blocks/{page_id}/children (block content, paginated)
//   → map → persist via DocumentRepository + DatabaseRepository

pub mod client;
pub mod mapper;
pub mod schema;

use std::collections::HashMap;

use uuid::Uuid;

use crate::application::database_repository::DatabaseRepository;
use crate::application::database_use_cases;
use crate::application::folder_repository::FolderRepository;
use crate::application::repository::DocumentRepository;
use crate::application::use_cases;
use crate::domain::database::{Property, PropertyType, PropertyValue};
use crate::domain::document::InlineText;
use crate::extractors::traits::Extractor;
use crate::extractors::{ExtractorError, ImportResult};
use crate::infrastructure::no_op_unit_of_work::NoOpUnitOfWork;

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

        let page_prop = Property::new("__pinkha_page__", PropertyType::Text);
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
        let mut notion_to_pinkha: HashMap<String, Uuid> = HashMap::new();

        let mut cursor: Option<String> = None;

        loop {
            let response = client.query_database(&db_id, cursor.as_deref()).await?;

            for page in &response.results {
                let (block_count, skipped_count, pinkha_doc_id, child_doc_count) = import_page(
                    &client,
                    page,
                    pinkha_db_id,
                    name_prop_id,
                    page_prop_id,
                    &prop_map,
                    docs,
                    dbs,
                    config.covers_dir.as_deref(),
                    &mut notion_to_pinkha,
                )
                .await?;

                notion_to_pinkha.insert(normalize_notion_id(&page.id), pinkha_doc_id);

                // The database row contributes the page itself; nested
                // child_page blocks turn into additional pinkha documents
                // counted here so the import summary stays truthful.
                total_documents += 1 + child_doc_count;
                total_entries += 1;
                total_blocks += block_count;
                total_skipped += skipped_count;
            }

            if !response.has_more {
                break;
            }
            cursor = response.next_cursor;
        }

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

// ── Page import helper ────────────────────────────────────────────────────────

/// Imports one Notion page: creates a Pinkha document, fetches its blocks,
/// and adds a database entry that back-links to the document.
///
/// Returns `(block_count, skipped_count, pinkha_doc_id)` — the doc id is
/// captured by the caller into the Notion→Pinkha map used for rewriting
/// mention links in the second pass.
#[allow(clippy::too_many_arguments)]
async fn import_page(
    client: &NotionClient,
    page: &schema::NotionPageResult,
    pinkha_db_id: Uuid,
    name_prop_id: Uuid,
    page_prop_id: Uuid,
    prop_map: &HashMap<String, Uuid>,
    docs: &(dyn DocumentRepository + Send + Sync),
    dbs: &(dyn DatabaseRepository + Send + Sync),
    covers_dir: Option<&str>,
    notion_to_pinkha: &mut HashMap<String, Uuid>,
) -> Result<(usize, usize, Uuid, usize), ExtractorError> {
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

    database_use_cases::add_entry_with_document(&uow, pinkha_db_id, values, doc_id)?;

    Ok((block_count, skipped_count, doc_id, child_doc_count))
}

// ── Cover image download ──────────────────────────────────────────────────────

/// Downloads `url` to `covers_dir/{doc_id}.{ext}` and returns the file name
/// (relative — the Swift renderer resolves it via its covers directory).
///
/// Notion serves cover images at unauthenticated URLs (even for Notion-hosted
/// covers), so we issue the GET with a fresh client to avoid sending the bearer
/// token to AWS S3. Returns an error string the caller can fall back from when
/// the network / disk write fails.
async fn download_cover(
    _client: &NotionClient,
    url: &str,
    covers_dir: &str,
    doc_id: Uuid,
) -> Result<String, String> {
    // The auth-less client: Notion covers don't accept the `Authorization`
    // header (especially on the S3 redirect step), and we don't want to leak
    // the bearer token to AWS even if it did.
    let http = reqwest::Client::builder()
        .build()
        .map_err(|e| format!("client build: {e}"))?;
    let response = http
        .get(url)
        .send()
        .await
        .map_err(|e| format!("GET {url}: {e}"))?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("HTTP {} for {url}", status.as_u16()));
    }
    let extension = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .and_then(extension_for_content_type)
        .or_else(|| extension_from_url_path(url))
        .unwrap_or("jpg")
        .to_owned();
    let bytes = response
        .bytes()
        .await
        .map_err(|e| format!("read body: {e}"))?;
    let filename = format!("{doc_id}.{extension}");
    let mut path = std::path::PathBuf::from(covers_dir);
    path.push(&filename);
    std::fs::write(&path, &bytes).map_err(|e| format!("write {path:?}: {e}"))?;
    Ok(filename)
}

/// Downloads an icon URL to disk when a covers directory is configured,
/// otherwise returns the original URL. The local filename uses a `-icon`
/// suffix so it can coexist with the page cover.
async fn download_or_keep_icon(
    client: &NotionClient,
    url: &str,
    covers_dir: Option<&str>,
    doc_id: Uuid,
) -> String {
    let Some(dir) = covers_dir else {
        return url.to_owned();
    };
    match download_icon(client, url, dir, doc_id).await {
        Ok(filename) => filename,
        Err(_) => url.to_owned(),
    }
}

/// Same shape as `download_cover` but with a `-icon` suffix in the filename
/// so a doc with both cover and icon doesn't overwrite one with the other.
async fn download_icon(
    _client: &NotionClient,
    url: &str,
    covers_dir: &str,
    doc_id: Uuid,
) -> Result<String, String> {
    let http = reqwest::Client::builder()
        .build()
        .map_err(|e| e.to_string())?;
    let response = http.get(url).send().await.map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status().as_u16()));
    }
    let extension = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .and_then(extension_for_content_type)
        .or_else(|| extension_from_url_path(url))
        .unwrap_or("png")
        .to_owned();
    let bytes = response.bytes().await.map_err(|e| e.to_string())?;
    let filename = format!("{doc_id}-icon.{extension}");
    let mut path = std::path::PathBuf::from(covers_dir);
    path.push(&filename);
    std::fs::write(&path, &bytes).map_err(|e| e.to_string())?;
    Ok(filename)
}

/// Reduces a `NotionPageIcon` to the string we persist in
/// `Database.icon` / `Document.icon` : the emoji glyph for `Emoji`
/// icons, the URL for `External` / `File` (image) icons, or `None`
/// for the catch-all unknown variant.
fn notion_icon_identifier(icon: &schema::NotionPageIcon) -> Option<String> {
    use schema::NotionPageIcon::*;
    match icon {
        Emoji { emoji } => Some(emoji.clone()),
        External { external } => Some(external.url.clone()),
        File { file } => Some(file.url.clone()),
        Unknown => None,
    }
}

/// Maps a `Content-Type` header value to a sensible file extension. Returns
/// `None` for types we don't have an extension for, letting the caller try
/// other heuristics or fall back to `"jpg"`.
fn extension_for_content_type(content_type: &str) -> Option<&'static str> {
    let main = content_type.split(';').next().unwrap_or("").trim();
    match main.to_ascii_lowercase().as_str() {
        "image/jpeg" | "image/jpg" => Some("jpg"),
        "image/png" => Some("png"),
        "image/heic" => Some("heic"),
        "image/webp" => Some("webp"),
        "image/gif" => Some("gif"),
        _ => None,
    }
}

/// Falls back to the URL's path extension when the server didn't send a
/// usable `Content-Type`.
fn extension_from_url_path(url: &str) -> Option<&'static str> {
    let path = url.split('?').next()?;
    let (_, ext) = path.rsplit_once('.')?;
    match ext.to_ascii_lowercase().as_str() {
        "jpg" | "jpeg" => Some("jpg"),
        "png" => Some("png"),
        "heic" => Some("heic"),
        "webp" => Some("webp"),
        "gif" => Some("gif"),
        _ => None,
    }
}

// ── Mention rewriting ─────────────────────────────────────────────────────────

/// Normalises a Notion ID (page or block) for use as a `HashMap` key.
///
/// Notion sometimes returns IDs with dashes (`1234abcd-...-...`), sometimes
/// without (in URLs). Strip the dashes and lower-case so equivalent IDs hash
/// to the same bucket.
pub fn normalize_notion_id(raw: &str) -> String {
    raw.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .flat_map(|c| c.to_lowercase())
        .collect()
}

/// Walks a Pinkha document loaded from `docs` and rewrites every inline link
/// whose URL embeds a Notion page ID we just imported. The new URL points to
/// the corresponding Pinkha document via the `pinkha://doc/{uuid}` scheme.
///
/// Persists the document only when at least one link was rewritten — keeps
/// I/O minimal for documents that don't cross-reference anything.
pub fn rewrite_notion_mentions(
    docs: &(dyn DocumentRepository + Send + Sync),
    doc_id: Uuid,
    notion_to_pinkha: &HashMap<String, Uuid>,
) -> Result<(), ExtractorError> {
    rewrite_notion_mentions_logged(docs, doc_id, notion_to_pinkha, None)
}

/// Logging variant — same behaviour as `rewrite_notion_mentions` but
/// appends a one-line summary to `<covers_dir>/notion-debug.log` so the
/// app can later report on link rewrites and Page-block promotions.
pub fn rewrite_notion_mentions_logged(
    docs: &(dyn DocumentRepository + Send + Sync),
    doc_id: Uuid,
    notion_to_pinkha: &HashMap<String, Uuid>,
    covers_dir: Option<&str>,
) -> Result<(), ExtractorError> {
    use crate::application::error::PinkhaError;
    let mut doc = docs.load(doc_id).map_err(|e: PinkhaError| match e {
        PinkhaError::NotFound(_) => ExtractorError::Parse(format!("doc {doc_id} not found")),
        other => ExtractorError::Parse(other.to_string()),
    })?;
    let mut rewrote = false;
    for block in doc.blocks.iter_mut() {
        rewrite_block_links(block, notion_to_pinkha, &mut rewrote);
    }
    // Second sub-pass : promote paragraphs that contain *only* a single
    // `pinkha://doc/{uuid}` link to a first-class `Page` block. Notion
    // never returns these references as `child_page` blocks (they're
    // page mentions inside paragraphs), so without this promotion the
    // imported docs render their sub-page references as inline links
    // instead of the chunky tappable rows users expect.
    let mut promoted_count = 0;
    promote_page_link_paragraphs(&mut doc.blocks, &mut promoted_count);
    if let Some(dir) = covers_dir {
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(format!("{dir}/notion-debug.log"))
        {
            let _ = writeln!(
                f,
                "[rewrite] doc={doc_id} links_rewritten={rewrote} promotions={promoted_count}"
            );
            // Also dump non-promoted paragraphs that carry a pinkha link
            // so we can iterate on the promotion criterion. We re-walk
            // the just-updated tree; a no-op when everything promoted.
            dump_unpromoted_links(&doc.blocks, dir);
        }
    }
    if rewrote || promoted_count > 0 {
        docs.save(&doc)
            .map_err(|e| ExtractorError::Parse(e.to_string()))?;
    }
    Ok(())
}

/// Recursively walks the block tree and replaces paragraphs whose entire
/// content is a single `pinkha://doc/{uuid}` link with the dedicated
/// `BlockContent::Page { id }` block. Sets `*promoted = true` when at
/// least one block changes so the caller can skip a no-op save.
/// Writes the raw span shape of every paragraph that survived rewrite
/// but failed promotion. Picked up by the next iteration so we can
/// learn what the Notion data actually looks like.
fn dump_unpromoted_links(blocks: &[crate::domain::document::Block], dir: &str) {
    let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(format!("{dir}/notion-debug.log"))
    else {
        return;
    };
    walk_dump(blocks, &mut f);
}

fn walk_dump<W: std::io::Write>(blocks: &[crate::domain::document::Block], f: &mut W) {
    use crate::domain::document::BlockContent;
    for block in blocks {
        if let BlockContent::Text(spans) = &block.content {
            let has_pinkha_link = spans.iter().any(|s| {
                s.styles.iter().any(|st| {
                    matches!(st, chaqaq::InlineStyle::Link(url) if url.starts_with("pinkha://doc/"))
                })
            });
            if has_pinkha_link {
                let _ = writeln!(
                    f,
                    "[promote skip] {} spans: {}",
                    spans.len(),
                    spans
                        .iter()
                        .map(|s| {
                            let link = s.styles.iter().find_map(|st| {
                                if let chaqaq::InlineStyle::Link(u) = st {
                                    Some(u.as_str())
                                } else {
                                    None
                                }
                            });
                            format!("({:?}, link={:?})", s.content, link)
                        })
                        .collect::<Vec<_>>()
                        .join(" | ")
                );
            }
        }
        walk_dump(&block.children, f);
    }
}

fn promote_page_link_paragraphs(
    blocks: &mut [crate::domain::document::Block],
    promoted: &mut usize,
) {
    use crate::domain::document::BlockContent;
    for block in blocks.iter_mut() {
        if let BlockContent::Text(spans) = &block.content
            && let Some(child_id) = sole_pinkha_doc_link(spans)
        {
            block.content = BlockContent::Page { id: child_id };
            *promoted += 1;
        }
        promote_page_link_paragraphs(&mut block.children, promoted);
    }
}

/// Returns the doc UUID if `spans` collectively encode a single
/// `pinkha://doc/{uuid}` link — the signature of a Notion page mention
/// sitting alone on its line. Whitespace-only runs (Notion likes to
/// pad mentions with empty/blank runs) are ignored. Any non-link
/// substantive text, or multiple distinct link targets, bail out so
/// "see also: [link]" or "[a] and [b]" stay as inline paragraphs.
fn sole_pinkha_doc_link(spans: &[chaqaq::InlineText]) -> Option<Uuid> {
    let mut target: Option<Uuid> = None;
    for run in spans {
        let mut run_link: Option<&str> = None;
        for style in &run.styles {
            if let chaqaq::InlineStyle::Link(url) = style {
                if run_link.is_some() {
                    return None; // more than one link in the same run
                }
                run_link = Some(url.as_str());
            }
        }
        match run_link {
            Some(url) => {
                let suffix = url.strip_prefix("pinkha://doc/")?;
                let id = Uuid::parse_str(suffix).ok()?;
                match target {
                    Some(existing) if existing != id => return None,
                    _ => target = Some(id),
                }
            }
            None => {
                // No link on this run — only accept it as filler if it's
                // pure whitespace; any real text means the paragraph is
                // mixed content and we leave it alone.
                if !run.content.trim().is_empty() {
                    return None;
                }
            }
        }
    }
    target
}

/// Recursively rewrites links in `block` and its descendants. Sets
/// `*rewrote = true` if any link was changed so the caller can skip the
/// `save` when nothing changed.
fn rewrite_block_links(
    block: &mut crate::domain::document::Block,
    notion_to_pinkha: &HashMap<String, Uuid>,
    rewrote: &mut bool,
) {
    rewrite_inlines_in_content(&mut block.content, notion_to_pinkha, rewrote);
    for child in block.children.iter_mut() {
        rewrite_block_links(child, notion_to_pinkha, rewrote);
    }
}

/// Walks the inline-bearing variants of `BlockContent` and rewrites their
/// link styles. Variants without inline text (`Divider`, `Breadcrumb`,
/// `Database`, `Code`) are no-ops.
fn rewrite_inlines_in_content(
    content: &mut crate::domain::document::BlockContent,
    notion_to_pinkha: &HashMap<String, Uuid>,
    rewrote: &mut bool,
) {
    use crate::domain::document::BlockContent;
    let inlines: Option<&mut Vec<InlineText>> = match content {
        BlockContent::Text(t) => Some(t),
        BlockContent::Heading { text, .. } => Some(text),
        BlockContent::Quote { text, .. } => Some(text),
        BlockContent::Todo { text, .. } => Some(text),
        BlockContent::BulletedListItem(t) => Some(t),
        BlockContent::NumberedListItem(t) => Some(t),
        BlockContent::Divider
        | BlockContent::Breadcrumb
        | BlockContent::Database { .. }
        | BlockContent::Code { .. }
        | BlockContent::Page { .. }
        | BlockContent::Embed { .. } => None,
    };
    if let Some(spans) = inlines {
        for span in spans.iter_mut() {
            for style in span.styles.iter_mut() {
                if let chaqaq::InlineStyle::Link(url) = style
                    && let Some(new_url) = rewrite_url(url, notion_to_pinkha)
                {
                    *url = new_url;
                    *rewrote = true;
                }
            }
        }
    }
}

/// Returns `Some(new_url)` if `url` contains a known Notion page ID; `None`
/// otherwise. The pinkha scheme uses dashed UUIDs for human readability when
/// debugging logs — strict format isn't important since only the app parses
/// these URLs.
fn rewrite_url(url: &str, notion_to_pinkha: &HashMap<String, Uuid>) -> Option<String> {
    let normalized = normalize_notion_id(url);
    // A 32-hex page ID is buried somewhere in the URL — scan for one of our
    // known IDs as a substring. Linear in the map size, fine for typical
    // imports (~hundreds of pages).
    for (notion_id, pinkha_id) in notion_to_pinkha {
        if normalized.contains(notion_id) {
            return Some(format!("pinkha://doc/{pinkha_id}"));
        }
    }
    None
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
    notion_to_pinkha: &mut HashMap<String, Uuid>,
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
    notion_to_pinkha: &mut HashMap<String, Uuid>,
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
    notion_to_pinkha: &mut HashMap<String, Uuid>,
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
    notion_to_pinkha.insert(normalize_notion_id(notion_id), child_id);

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

#[cfg(test)]
mod mention_tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn normalize_strips_dashes_and_lowercases() {
        assert_eq!(
            normalize_notion_id("1234ABCD-EF56-7890-ABCD-EF1234567890"),
            "1234abcdef567890abcdef1234567890"
        );
        // Already-normalised IDs pass through unchanged.
        assert_eq!(
            normalize_notion_id("abc123def456abc123def456abc123de"),
            "abc123def456abc123def456abc123de"
        );
    }

    #[test]
    fn rewrite_url_matches_known_page_id() {
        let notion_id = "abc123def456abc123def456abc123de".to_string();
        let pinkha_id = Uuid::new_v4();
        let mut map = HashMap::new();
        map.insert(notion_id.clone(), pinkha_id);

        // Standard Notion page URL with dashes — must still match after
        // normalisation.
        let url = "https://www.notion.so/My-Page-abc123def456abc123def456abc123de";
        let rewritten = rewrite_url(url, &map).expect("expected rewrite");
        assert_eq!(rewritten, format!("pinkha://doc/{pinkha_id}"));
    }

    #[test]
    fn rewrite_url_returns_none_for_unknown_ids() {
        let map: HashMap<String, Uuid> = HashMap::new();
        let url = "https://www.notion.so/Some-Page-abc123def456abc123def456abc123de";
        assert!(rewrite_url(url, &map).is_none());
        // Non-Notion URLs aren't touched either.
        assert!(rewrite_url("https://example.com", &map).is_none());
    }
}
