// ── Notion extractor ──────────────────────────────────────────────────────────
//
// Pipeline: OAuth2 token (obtained by Swift) + database ID
//   → GET /v1/databases/{id}          (schema: properties + title)
//   → POST /v1/databases/{id}/query   (entries, paginated)
//   → GET /v1/blocks/{page_id}/children (block content, paginated)
//   → map → persist via DocumentRepository + DatabaseRepository

pub mod client;
pub mod schema;
pub mod mapper;

use std::collections::HashMap;

use uuid::Uuid;

use crate::application::database_repository::DatabaseRepository;
use crate::application::database_use_cases;
use crate::application::repository::DocumentRepository;
use crate::application::use_cases;
use crate::domain::database::{Property, PropertyType, PropertyValue};
use crate::domain::document::InlineText;
use crate::extractors::traits::Extractor;
use crate::extractors::{ExtractorError, ImportResult};

use self::client::NotionClient;
use self::mapper::{extract_database_id, map_block, map_property_type, map_property_value};
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
}

// ── Extractor ─────────────────────────────────────────────────────────────────

pub struct NotionExtractor;

impl NotionExtractor {
    pub fn new() -> Self {
        Self
    }
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
        let pinkha_db = database_use_cases::create_database(dbs, title_inlines, all_properties)?;
        let pinkha_db_id = pinkha_db.id;

        // 6. Paginate through all Notion pages (rows) and import each one.
        let mut total_documents: usize = 0;
        let mut total_entries: usize = 0;
        let mut total_blocks: usize = 0;
        let mut total_skipped: usize = 0;

        let mut cursor: Option<String> = None;

        loop {
            let response = client
                .query_database(&db_id, cursor.as_deref())
                .await?;

            for page in &response.results {
                let (block_count, skipped_count) = import_page(
                    &client,
                    page,
                    pinkha_db_id,
                    name_prop_id,
                    page_prop_id,
                    &prop_map,
                    docs,
                    dbs,
                )
                .await?;

                total_documents += 1;
                total_entries += 1;
                total_blocks += block_count;
                total_skipped += skipped_count;
            }

            if !response.has_more {
                break;
            }
            cursor = response.next_cursor;
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
/// Returns `(block_count, skipped_count)`.
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
) -> Result<(usize, usize), ExtractorError> {
    // Extract the page title from the "title" property type.
    let plain_title = page
        .properties
        .values()
        .find_map(|v| {
            if let NotionPagePropValue::Title { title } = v {
                Some(title.iter().map(|r| r.plain_text.as_str()).collect::<String>())
            } else {
                None
            }
        })
        .unwrap_or_else(|| "Untitled".to_string());

    // Create the Pinkha document.
    let doc = use_cases::create_document(docs, &plain_title)?;
    let doc_id = doc.id;

    // Fetch and add all blocks to the document efficiently (bulk in-memory, one save).
    let (block_count, skipped_count) = fetch_and_add_blocks(client, &page.id, doc_id, docs).await?;

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
    values.insert(
        page_prop_id,
        PropertyValue::Text(doc_id.to_string()),
    );

    // Notion properties → Pinkha property values.
    for (notion_name, pinkha_id) in prop_map {
        if let Some(notion_val) = page.properties.get(notion_name) {
            if let Some(pinkha_val) = map_property_value(notion_val) {
                values.insert(*pinkha_id, pinkha_val);
            }
        }
    }

    database_use_cases::add_entry(dbs, pinkha_db_id, values)?;

    Ok((block_count, skipped_count))
}

/// Paginates through a page's block children, appends them to the document in
/// memory, and saves once.
async fn fetch_and_add_blocks(
    client: &NotionClient,
    page_id: &str,
    doc_id: Uuid,
    docs: &(dyn DocumentRepository + Send + Sync),
) -> Result<(usize, usize), ExtractorError> {
    let mut all_block_contents = Vec::new();
    let mut skipped: usize = 0;
    let mut cursor: Option<String> = None;

    loop {
        let response = client.get_page_blocks(page_id, cursor.as_deref()).await?;

        for block in &response.results {
            match map_block(block) {
                Some(content) => all_block_contents.push(content),
                None => skipped += 1,
            }
        }

        if !response.has_more {
            break;
        }
        cursor = response.next_cursor;
    }

    let count = all_block_contents.len();

    // Bulk in-memory update: load → push all blocks → save once.
    let mut doc = docs.load(doc_id)?;
    for content in all_block_contents {
        doc.add_block(content);
    }
    docs.save(&doc)?;

    Ok((count, skipped))
}
