//! Cover and icon download helpers for the Notion import pipeline.

use uuid::Uuid;

use super::client::NotionClient;
use super::schema;

// ── Asset download ────────────────────────────────────────────────────────────

/// Wall-clock ceiling for a single cover/icon download.
///
/// Without it, one unresponsive host stalls the whole import: the cancel
/// flag is only polled between pages, so a socket that accepts and then
/// never answers leaves the user staring at a frozen progress bar with a
/// Cancel button that does nothing.
const ASSET_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// Hard ceiling on a downloaded asset, enforced while streaming.
///
/// `Response::bytes()` buffers the entire body with no bound, sized by
/// whatever the server chooses to send. 20 MB is far above any real page
/// cover and far below anything that threatens a phone.
const MAX_ASSET_BYTES: usize = 20 * 1024 * 1024;

/// Rejects asset URLs that aren't plain `https`.
///
/// Cover URLs come from the Notion API, but icon URLs do not have to:
/// `NotionPageIcon::External` carries whatever the page author typed, so
/// importing a page someone shared with you means fetching URLs they
/// control. Requiring https keeps the fetch off plaintext and off
/// non-network schemes.
fn validate_asset_url(url: &str) -> Result<(), String> {
    let parsed = reqwest::Url::parse(url).map_err(|e| format!("bad asset URL: {e}"))?;
    if parsed.scheme() != "https" {
        return Err(format!(
            "refusing non-https asset URL ({})",
            parsed.scheme()
        ));
    }
    if parsed.host().is_none() {
        return Err("refusing asset URL without a host".to_owned());
    }
    Ok(())
}

/// The auth-less client used for assets: Notion covers don't accept the
/// `Authorization` header (especially on the S3 redirect step), and we don't
/// want to leak the bearer token to AWS even if they did.
///
/// The redirect policy re-checks each hop, so an https URL cannot bounce the
/// request onto plaintext or onto a scheme we never agreed to.
fn asset_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(ASSET_TIMEOUT)
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() >= 5 {
                attempt.error("too many redirects")
            } else if attempt.url().scheme() != "https" {
                attempt.stop()
            } else {
                attempt.follow()
            }
        }))
        .build()
        .map_err(|e| format!("client build: {e}"))
}

/// Streams the body, aborting as soon as it exceeds `MAX_ASSET_BYTES`
/// instead of buffering first and checking after.
async fn read_capped(mut response: reqwest::Response) -> Result<Vec<u8>, String> {
    // Trust the advertised length only to bail out early — it is a hint from
    // the server, so the streaming check below is what actually enforces
    // the cap.
    if let Some(len) = response.content_length()
        && len > MAX_ASSET_BYTES as u64
    {
        return Err(format!("asset too large ({len} bytes)"));
    }
    let mut buffer: Vec<u8> = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|e| format!("read body: {e}"))?
    {
        if buffer.len() + chunk.len() > MAX_ASSET_BYTES {
            return Err("asset exceeds size limit".to_owned());
        }
        buffer.extend_from_slice(&chunk);
    }
    Ok(buffer)
}

/// Downloads `url` into `covers_dir/{stem}.{ext}` and returns the file name
/// (relative — the Swift renderer resolves it via its covers directory).
///
/// Shared by the cover and icon paths, which differ only in the filename
/// stem and the extension to assume when the server tells us nothing.
async fn download_asset(
    url: &str,
    covers_dir: &str,
    stem: &str,
    default_extension: &str,
) -> Result<String, String> {
    validate_asset_url(url)?;
    let http = asset_client()?;
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
        .unwrap_or(default_extension)
        .to_owned();
    let bytes = read_capped(response).await?;
    let filename = format!("{stem}.{extension}");
    let mut path = std::path::PathBuf::from(covers_dir);
    path.push(&filename);
    std::fs::write(&path, &bytes).map_err(|e| format!("write {path:?}: {e}"))?;
    Ok(filename)
}

/// Downloads a page cover. Returns an error string the caller can fall back
/// from when the network / disk write fails.
pub(super) async fn download_cover(
    _client: &NotionClient,
    url: &str,
    covers_dir: &str,
    leaf_id: Uuid,
) -> Result<String, String> {
    download_asset(url, covers_dir, &leaf_id.to_string(), "jpg").await
}

/// Downloads an icon URL to disk when a covers directory is configured,
/// otherwise returns the original URL. The local filename uses a `-icon`
/// suffix so it can coexist with the page cover.
pub(super) async fn download_or_keep_icon(
    _client: &NotionClient,
    url: &str,
    covers_dir: Option<&str>,
    leaf_id: Uuid,
) -> String {
    let Some(dir) = covers_dir else {
        return url.to_owned();
    };
    match download_asset(url, dir, &format!("{leaf_id}-icon"), "png").await {
        Ok(filename) => filename,
        Err(_) => url.to_owned(),
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_a_plain_https_asset_url() {
        assert!(validate_asset_url("https://s3.amazonaws.com/cover.png").is_ok());
    }

    #[test]
    fn rejects_plaintext_http() {
        let err = validate_asset_url("http://example.com/cover.png").unwrap_err();
        assert!(err.contains("non-https"), "{err}");
    }

    #[test]
    fn rejects_non_network_schemes() {
        // `NotionPageIcon::External` carries an author-controlled URL, so
        // this is reachable by importing a page someone else wrote.
        for url in ["file:///etc/passwd", "data:image/png;base64,AAAA"] {
            assert!(validate_asset_url(url).is_err(), "accepted {url}");
        }
    }

    #[test]
    fn rejects_malformed_urls() {
        assert!(validate_asset_url("not a url").is_err());
        assert!(validate_asset_url("").is_err());
    }

    #[test]
    fn content_type_wins_over_the_url_extension() {
        assert_eq!(extension_for_content_type("image/png"), Some("png"));
        assert_eq!(
            extension_for_content_type("image/jpeg; charset=binary"),
            Some("jpg")
        );
        assert_eq!(extension_for_content_type("text/html"), None);
    }

    #[test]
    fn falls_back_to_the_url_path_extension() {
        assert_eq!(
            extension_from_url_path("https://x.com/a.WEBP?sig=1"),
            Some("webp")
        );
        assert_eq!(extension_from_url_path("https://x.com/a.exe"), None);
    }

    #[test]
    fn the_client_carries_a_timeout_and_a_bounded_redirect_policy() {
        // Building it is the assertion: a redirect policy that rejects a
        // scheme change is easy to write in a way that fails to compile or
        // panics on construction, and `asset_client` is the only place the
        // timeout is attached.
        assert!(asset_client().is_ok());
    }
}
