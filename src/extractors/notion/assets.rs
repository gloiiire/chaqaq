//! Cover and icon download helpers for the Notion import pipeline.

use uuid::Uuid;

use super::client::NotionClient;
use super::schema;

// ── Cover image download ──────────────────────────────────────────────────────

/// Downloads `url` to `covers_dir/{leaf_id}.{ext}` and returns the file name
/// (relative — the Swift renderer resolves it via its covers directory).
///
/// Notion serves cover images at unauthenticated URLs (even for Notion-hosted
/// covers), so we issue the GET with a fresh client to avoid sending the bearer
/// token to AWS S3. Returns an error string the caller can fall back from when
/// the network / disk write fails.
pub(super) async fn download_cover(
    _client: &NotionClient,
    url: &str,
    covers_dir: &str,
    leaf_id: Uuid,
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
    let filename = format!("{leaf_id}.{extension}");
    let mut path = std::path::PathBuf::from(covers_dir);
    path.push(&filename);
    std::fs::write(&path, &bytes).map_err(|e| format!("write {path:?}: {e}"))?;
    Ok(filename)
}

/// Downloads an icon URL to disk when a covers directory is configured,
/// otherwise returns the original URL. The local filename uses a `-icon`
/// suffix so it can coexist with the page cover.
pub(super) async fn download_or_keep_icon(
    client: &NotionClient,
    url: &str,
    covers_dir: Option<&str>,
    leaf_id: Uuid,
) -> String {
    let Some(dir) = covers_dir else {
        return url.to_owned();
    };
    match download_icon(client, url, dir, leaf_id).await {
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
    leaf_id: Uuid,
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
    let filename = format!("{leaf_id}-icon.{extension}");
    let mut path = std::path::PathBuf::from(covers_dir);
    path.push(&filename);
    std::fs::write(&path, &bytes).map_err(|e| e.to_string())?;
    Ok(filename)
}

/// Reduces a `NotionPageIcon` to the string we persist in
/// `Book.icon` / `Leaf.icon` : the emoji glyph for `Emoji`
/// icons, the URL for `External` / `File` (image) icons, or `None`
/// for the catch-all unknown variant.
pub(super) fn notion_icon_identifier(icon: &schema::NotionPageIcon) -> Option<String> {
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
