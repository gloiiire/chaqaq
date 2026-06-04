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
            rewrite_notion_mentions(docs, *pinkha_doc_id, &notion_to_pinkha)?;
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

    // Create the Pinkha document.
    let uow = NoOpUnitOfWork::with_docs_dbs(docs, dbs);
    let doc = use_cases::create_document(&uow, &plain_title)?;
    let doc_id = doc.id;

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
    use crate::application::error::PinkhaError;
    let mut doc = docs.load(doc_id).map_err(|e: PinkhaError| match e {
        PinkhaError::NotFound(_) => ExtractorError::Parse(format!("doc {doc_id} not found")),
        other => ExtractorError::Parse(other.to_string()),
    })?;
    let mut rewrote = false;
    for block in doc.blocks.iter_mut() {
        rewrite_block_links(block, notion_to_pinkha, &mut rewrote);
    }
    if rewrote {
        docs.save(&doc)
            .map_err(|e| ExtractorError::Parse(e.to_string()))?;
    }
    Ok(())
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
        | BlockContent::Page { .. } => None,
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
        fetch_blocks_recursive(client, page_id, doc_id, docs, notion_to_pinkha, covers_dir)
            .await?;

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
    if let Ok(meta) = client.get_page(notion_id).await {
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
