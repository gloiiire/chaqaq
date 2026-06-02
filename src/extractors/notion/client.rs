// ── Notion API HTTP client ─────────────────────────────────────────────────────
//
// Thin reqwest wrapper that handles auth headers and error extraction.
// Rate-limit retry is left to a future iteration.

use super::schema::{NotionBlocksResponse, NotionDatabaseSchema, NotionQueryResponse, NotionSearchResponse};
use crate::extractors::ExtractorError;
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION};

/// Reusable HTTP client for the Notion API v1.
pub struct NotionClient {
    client: reqwest::Client,
}

impl NotionClient {
    /// Builds a client with `Authorization: Bearer {token}` and `Notion-Version` pre-set.
    pub fn new(token: &str) -> Result<Self, ExtractorError> {
        let mut headers = HeaderMap::new();

        let auth_value = format!("Bearer {token}");
        let mut auth_header = HeaderValue::from_str(&auth_value)
            .map_err(|e| ExtractorError::Auth(e.to_string()))?;
        auth_header.set_sensitive(true);
        headers.insert(AUTHORIZATION, auth_header);

        headers.insert(
            "Notion-Version",
            HeaderValue::from_static("2022-06-28"),
        );

        let client = reqwest::Client::builder()
            .default_headers(headers)
            .build()
            .map_err(|e| ExtractorError::Parse(e.to_string()))?;

        Ok(Self { client })
    }

    /// Fetches the schema (property definitions + title) for a Notion database.
    pub async fn get_database(&self, db_id: &str) -> Result<NotionDatabaseSchema, ExtractorError> {
        let url = format!("https://api.notion.com/v1/databases/{db_id}");
        let resp = self.client.get(&url).send().await?;
        let bytes = self.extract_ok(resp).await?;
        let schema: NotionDatabaseSchema = serde_json::from_slice(&bytes)?;
        Ok(schema)
    }

    /// Queries a database page by page.
    ///
    /// Pass `cursor = Some(token)` to resume pagination.
    pub async fn query_database(
        &self,
        db_id: &str,
        cursor: Option<&str>,
    ) -> Result<NotionQueryResponse, ExtractorError> {
        let url = format!("https://api.notion.com/v1/databases/{db_id}/query");

        let body = if let Some(c) = cursor {
            serde_json::json!({ "start_cursor": c })
        } else {
            serde_json::json!({})
        };

        let resp = self
            .client
            .post(&url)
            .json(&body)
            .send()
            .await?;
        let bytes = self.extract_ok(resp).await?;
        let result: NotionQueryResponse = serde_json::from_slice(&bytes)?;
        Ok(result)
    }

    /// Lists every database the current integration has been granted access
    /// to, across all authorised workspaces. Uses Notion's `POST /v1/search`
    /// with a filter restricting results to the `database` object type.
    ///
    /// Paginates internally and returns the fully concatenated list — the
    /// caller doesn't deal with cursors. A user with a fresh OAuth grant on
    /// 3 workspaces with ~10 databases each fits comfortably in a single
    /// page; pagination is only there to honour the API contract.
    pub async fn list_accessible_databases(
        &self,
    ) -> Result<Vec<super::schema::NotionDatabaseSearchHit>, ExtractorError> {
        let url = "https://api.notion.com/v1/search";
        let mut results: Vec<super::schema::NotionDatabaseSearchHit> = Vec::new();
        let mut cursor: Option<String> = None;
        loop {
            let body = match cursor.as_deref() {
                None => serde_json::json!({
                    "filter": { "property": "object", "value": "database" },
                    "page_size": 100,
                }),
                Some(c) => serde_json::json!({
                    "filter": { "property": "object", "value": "database" },
                    "page_size": 100,
                    "start_cursor": c,
                }),
            };
            let response = self.client.post(url).json(&body).send().await?;
            let bytes = self.extract_ok(response).await?;
            let parsed: NotionSearchResponse = serde_json::from_slice(&bytes)?;
            results.extend(parsed.results);
            if !parsed.has_more {
                break;
            }
            cursor = parsed.next_cursor;
        }
        Ok(results)
    }

    /// Fetches the children blocks of a page, 100 at a time.
    pub async fn get_page_blocks(
        &self,
        page_id: &str,
        cursor: Option<&str>,
    ) -> Result<NotionBlocksResponse, ExtractorError> {
        let mut url = format!(
            "https://api.notion.com/v1/blocks/{page_id}/children?page_size=100"
        );
        if let Some(c) = cursor {
            url.push_str("&start_cursor=");
            url.push_str(c);
        }

        let resp = self.client.get(&url).send().await?;
        let bytes = self.extract_ok(resp).await?;
        let result: NotionBlocksResponse = serde_json::from_slice(&bytes)?;
        Ok(result)
    }

    /// Reads the response bytes; on non-2xx status, extracts the API error message.
    async fn extract_ok(
        &self,
        resp: reqwest::Response,
    ) -> Result<Vec<u8>, ExtractorError> {
        let status = resp.status();
        let bytes = resp.bytes().await.map(|b| b.to_vec())?;

        if !status.is_success() {
            // Try to extract the `message` field from Notion's error JSON.
            let message = serde_json::from_slice::<serde_json::Value>(&bytes)
                .ok()
                .and_then(|v| v["message"].as_str().map(str::to_owned))
                .unwrap_or_else(|| format!("HTTP {}", status.as_u16()));

            if status.as_u16() == 401 {
                return Err(ExtractorError::Auth(message));
            }
            return Err(ExtractorError::Http {
                status: status.as_u16(),
                message,
            });
        }

        Ok(bytes)
    }
}
