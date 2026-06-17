// ── Notion API HTTP client ─────────────────────────────────────────────────────
//
// Thin reqwest wrapper that handles auth headers and error extraction.
// Rate-limit retry is left to a future iteration.

use super::schema::{
    NotionBlocksResponse, NotionDatabaseSchema, NotionQueryResponse, NotionSearchResponse,
};
use crate::extractors::ExtractorError;
use reqwest::header::{AUTHORIZATION, HeaderMap, HeaderValue};

/// Reusable HTTP client for the Notion API v1.
pub struct NotionClient {
    client: reqwest::Client,
}

impl NotionClient {
    /// Builds a client with `Authorization: Bearer {token}` and `Notion-Version` pre-set.
    pub fn new(token: &str) -> Result<Self, ExtractorError> {
        let mut headers = HeaderMap::new();

        let auth_value = format!("Bearer {token}");
        let mut auth_header =
            HeaderValue::from_str(&auth_value).map_err(|e| ExtractorError::Auth(e.to_string()))?;
        auth_header.set_sensitive(true);
        headers.insert(AUTHORIZATION, auth_header);

        headers.insert("Notion-Version", HeaderValue::from_static("2022-06-28"));

        let client = reqwest::Client::builder()
            .default_headers(headers)
            // Cap individual requests so a single hung connection doesn't
            // stall the whole import — Notion will return 429 on rate
            // limit but never closes the socket itself.
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .map_err(|e| ExtractorError::Parse(e.to_string()))?;

        Ok(Self { client })
    }

    /// Fetches the schema (property definitions + title) for a Notion book.
    pub async fn get_book(&self, book_id: &str) -> Result<NotionDatabaseSchema, ExtractorError> {
        let url = format!("https://api.notion.com/v1/databases/{book_id}");
        let bytes = self.send_with_backoff(self.client.get(&url)).await?;
        let schema: NotionDatabaseSchema = serde_json::from_slice(&bytes)?;
        Ok(schema)
    }

    /// Queries a book page by page.
    ///
    /// Pass `cursor = Some(token)` to resume pagination.
    pub async fn query_book(
        &self,
        book_id: &str,
        cursor: Option<&str>,
    ) -> Result<NotionQueryResponse, ExtractorError> {
        let url = format!("https://api.notion.com/v1/databases/{book_id}/query");

        let body = if let Some(c) = cursor {
            serde_json::json!({ "start_cursor": c })
        } else {
            serde_json::json!({})
        };

        let bytes = self
            .send_with_backoff(self.client.post(&url).json(&body))
            .await?;
        let result: NotionQueryResponse = serde_json::from_slice(&bytes)?;
        Ok(result)
    }

    /// Lists every book the current integration has been granted access
    /// to, across all authorised workspaces. Uses Notion's `POST /v1/search`
    /// with a filter restricting results to the `database` object type
    /// (Notion's API term, not our internal `Book` rename).
    ///
    /// Paginates internally and returns the fully concatenated list — the
    /// caller doesn't deal with cursors. A user with a fresh OAuth grant on
    /// 3 workspaces with ~10 books each fits comfortably in a single
    /// page; pagination is only there to honour the API contract.
    pub async fn list_accessible_books(
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
            let bytes = self
                .send_with_backoff(self.client.post(url).json(&body))
                .await?;
            let parsed: NotionSearchResponse = serde_json::from_slice(&bytes)?;
            results.extend(parsed.results);
            if !parsed.has_more {
                break;
            }
            cursor = parsed.next_cursor;
        }
        Ok(results)
    }

    /// 2025-09-03 API : lists data sources the integration can read.
    /// Used by the new picker path so multi-source books (which
    /// the legacy `book`-filtered search may skip) surface in the
    /// import dialog. The default `Notion-Version: 2022-06-28` header
    /// baked into the client is overridden per-request so the
    /// existing import flow stays on the legacy contract — only the
    /// data-source enumeration uses the new version.
    pub async fn list_accessible_data_sources(
        &self,
    ) -> Result<Vec<super::schema::NotionDataSourceSearchHit>, ExtractorError> {
        let url = "https://api.notion.com/v1/search";
        let mut results: Vec<super::schema::NotionDataSourceSearchHit> = Vec::new();
        let mut cursor: Option<String> = None;
        loop {
            let body = match cursor.as_deref() {
                None => serde_json::json!({
                    "filter": { "property": "object", "value": "data_source" },
                    "page_size": 100,
                }),
                Some(c) => serde_json::json!({
                    "filter": { "property": "object", "value": "data_source" },
                    "page_size": 100,
                    "start_cursor": c,
                }),
            };
            let bytes = self
                .send_with_backoff(
                    self.client
                        .post(url)
                        .header("Notion-Version", "2025-09-03")
                        .json(&body),
                )
                .await?;
            let parsed: super::schema::NotionDataSourceSearchResponse =
                serde_json::from_slice(&bytes)?;
            results.extend(parsed.results);
            if !parsed.has_more {
                break;
            }
            cursor = parsed.next_cursor;
        }
        Ok(results)
    }

    /// Lists every page the integration has been granted access to.
    /// Used by the v2025 picker walker so we can scan each shared
    /// page for `child_database` blocks that the `object: database`
    /// search doesn't enumerate by itself.
    pub async fn list_accessible_pages(
        &self,
    ) -> Result<Vec<super::schema::NotionPageSearchHit>, ExtractorError> {
        let url = "https://api.notion.com/v1/search";
        let mut results: Vec<super::schema::NotionPageSearchHit> = Vec::new();
        let mut cursor: Option<String> = None;
        loop {
            let body = match cursor.as_deref() {
                None => serde_json::json!({
                    "filter": { "property": "object", "value": "page" },
                    "page_size": 100,
                }),
                Some(c) => serde_json::json!({
                    "filter": { "property": "object", "value": "page" },
                    "page_size": 100,
                    "start_cursor": c,
                }),
            };
            let bytes = self
                .send_with_backoff(self.client.post(url).json(&body))
                .await?;
            let parsed: super::schema::NotionPageSearchResponse = serde_json::from_slice(&bytes)?;
            results.extend(parsed.results);
            if !parsed.has_more {
                break;
            }
            cursor = parsed.next_cursor;
        }
        Ok(results)
    }

    /// Shallow scan of a page's top-level block list for
    /// `child_database` entries. Each block's `id` IS the wrapping
    /// book's Notion id, so the result feeds straight into the
    /// picker.
    ///
    /// Deliberately :
    ///   * No recursion into nested `child_page` blocks — that
    ///     compounds with Notion's 3 req/sec rate limit into
    ///     minute-long picker loads on real accounts. Users who
    ///     need a deeply-nested DB can share the immediate parent
    ///     page with the integration.
    ///   * Single 100-block request per page — Notion paginates
    ///     beyond that, but in practice a book hub page has
    ///     its DBs near the top of the block list. Beyond 100
    ///     blocks the user can paste the URL directly.
    pub async fn list_child_databases_in_page(
        &self,
        page_id: &str,
    ) -> Result<Vec<(String, String)>, ExtractorError> {
        let resp = self.get_page_blocks(page_id, None).await?;
        let mut collected: Vec<(String, String)> = Vec::new();
        for block in resp.results {
            if block.type_ == "child_database" {
                let title = block
                    .child_database
                    .as_ref()
                    .map(|c| c.title.clone())
                    .unwrap_or_default();
                collected.push((block.id.clone(), title));
            }
        }
        Ok(collected)
    }

    /// Fetches a single page's metadata — properties, icon, cover.
    /// Used by the child-page import path : when we encounter a
    /// `child_page` block inside another page, its block payload only
    /// carries the title, so we hit `/v1/pages/{id}` to materialise the
    /// icon (and cover, when set) onto the freshly-created pinkha doc.
    pub async fn get_page(
        &self,
        page_id: &str,
    ) -> Result<super::schema::NotionPageResult, ExtractorError> {
        let url = format!("https://api.notion.com/v1/pages/{page_id}");
        let bytes = self.send_with_backoff(self.client.get(&url)).await?;
        let page: super::schema::NotionPageResult = serde_json::from_slice(&bytes)?;
        Ok(page)
    }

    /// Fetches the children blocks of a page, 100 at a time.
    pub async fn get_page_blocks(
        &self,
        page_id: &str,
        cursor: Option<&str>,
    ) -> Result<NotionBlocksResponse, ExtractorError> {
        let mut url = format!("https://api.notion.com/v1/blocks/{page_id}/children?page_size=100");
        if let Some(c) = cursor {
            url.push_str("&start_cursor=");
            url.push_str(c);
        }

        let bytes = self.send_with_backoff(self.client.get(&url)).await?;
        let result: NotionBlocksResponse = serde_json::from_slice(&bytes)?;
        Ok(result)
    }

    /// Sends a request with exponential-backoff retries on transient
    /// failures (429 rate-limit, 5xx, network drops). Permanent
    /// errors (401 auth, 4xx other than 429) abort the retry loop
    /// immediately. The `RequestBuilder` is cloned via `try_clone`
    /// for each attempt — should always succeed for our usage since
    /// every body we send is a serialised JSON `serde_json::Value`
    /// (cloneable).
    ///
    /// Hand-rolled loop (no `backoff` crate — it is unmaintained,
    /// RUSTSEC-2024-0384) : 500ms initial interval, 2× multiplier,
    /// 8s max interval, 30s total elapsed budget, no jitter. The
    /// picker hits the success path on the first attempt — the
    /// retries only kick in during heavy import flows where the
    /// 3 req/sec Notion rate limit becomes a factor.
    async fn send_with_backoff(
        &self,
        builder: reqwest::RequestBuilder,
    ) -> Result<Vec<u8>, ExtractorError> {
        const INITIAL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(500);
        const MAX_INTERVAL: std::time::Duration = std::time::Duration::from_secs(8);
        const MAX_ELAPSED: std::time::Duration = std::time::Duration::from_secs(30);

        let start = std::time::Instant::now();
        let mut interval = INITIAL_INTERVAL;
        loop {
            let attempt = builder.try_clone().ok_or_else(|| {
                ExtractorError::Parse("request builder not cloneable".to_string())
            })?;
            let error = match Self::execute_once(attempt).await {
                Ok(bytes) => return Ok(bytes),
                Err(Retry::Permanent(e)) => return Err(e),
                Err(Retry::Transient(e)) => e,
            };
            // Give up once the next sleep would blow the elapsed budget.
            if start.elapsed() + interval > MAX_ELAPSED {
                return Err(error);
            }
            tokio::time::sleep(interval).await;
            interval = (interval * 2).min(MAX_INTERVAL);
        }
    }

    /// Single request attempt — classifies every failure as transient
    /// (worth retrying) or permanent (abort immediately).
    async fn execute_once(attempt: reqwest::RequestBuilder) -> Result<Vec<u8>, Retry> {
        // Network-level failures (timeout, connection reset) are transient.
        let response = attempt
            .send()
            .await
            .map_err(|e| Retry::Transient(ExtractorError::from(e)))?;
        let status = response.status();
        let bytes = response
            .bytes()
            .await
            .map(|b| b.to_vec())
            .map_err(|e| Retry::Transient(ExtractorError::from(e)))?;
        if status.is_success() {
            return Ok(bytes);
        }
        let message = serde_json::from_slice::<serde_json::Value>(&bytes)
            .ok()
            .and_then(|v| v["message"].as_str().map(str::to_owned))
            .unwrap_or_else(|| format!("HTTP {}", status.as_u16()));
        let code = status.as_u16();
        // 401 — auth dead, can't recover by retrying.
        if code == 401 {
            return Err(Retry::Permanent(ExtractorError::Auth(message)));
        }
        // 429 (rate limit) + every 5xx → transient; sleep then retry.
        if code == 429 || (500..=599).contains(&code) {
            return Err(Retry::Transient(ExtractorError::Http {
                status: code,
                message,
            }));
        }
        // Everything else (404, 403, 400…) is a permanent client
        // error — don't waste retries on it.
        Err(Retry::Permanent(ExtractorError::Http {
            status: code,
            message,
        }))
    }
}

/// Retry classification for a failed request attempt.
enum Retry {
    /// Worth retrying after a backoff sleep.
    Transient(ExtractorError),
    /// Retrying cannot help — surface the error immediately.
    Permanent(ExtractorError),
}
