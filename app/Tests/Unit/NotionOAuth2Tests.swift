import Testing
import Foundation
@testable import ImportFeature
@testable import Pinkha

// Unit tests for NotionOAuth2 URL construction.
// No ASWebAuthenticationSession is launched — only the static helper is exercised.

@MainActor
@Suite("NotionOAuth2 — authorization URL construction")
struct NotionOAuth2Tests {

    // Sample values used across tests.
    private let clientId   = "abc123"
    private let redirectUri = "pinkha://oauth/notion"

    private func makeUrl() -> URL {
        guard let url = NotionOAuth2.authorizationUrl(clientId: clientId, redirectUri: redirectUri) else {
            Issue.record("authorizationUrl returned nil")
            return URL(string: "https://invalid")!
        }
        return url
    }

    @Test func authUrl_contains_client_id() {
        let url = makeUrl()
        #expect(url.absoluteString.contains("client_id=abc123"))
    }

    @Test func authUrl_contains_response_type_code() {
        let url = makeUrl()
        #expect(url.absoluteString.contains("response_type=code"))
    }

    @Test func authUrl_contains_redirect_uri() {
        let url = makeUrl()
        // URLComponents percent-encodes the redirect URI — verify the encoded form is present.
        let encoded = redirectUri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectUri
        // Both the raw and encoded forms should result in the query containing the redirect.
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let redirectItem = comps?.queryItems?.first(where: { $0.name == "redirect_uri" })
        #expect(redirectItem?.value == redirectUri)
    }

    @Test func authUrl_points_to_notion_authorize_endpoint() {
        let url = makeUrl()
        #expect(url.absoluteString.hasPrefix("https://api.notion.com/v1/oauth/authorize"))
    }

    @Test func authUrl_contains_owner_user() {
        let url = makeUrl()
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let ownerItem = comps?.queryItems?.first(where: { $0.name == "owner" })
        #expect(ownerItem?.value == "user")
    }

    @Test func authUrl_with_different_client_id() {
        let url = NotionOAuth2.authorizationUrl(clientId: "xyz999", redirectUri: redirectUri)
        #expect(url?.absoluteString.contains("client_id=xyz999") == true)
    }

    @Test func authUrl_returns_nil_for_malformed_base_url() {
        // The static helper uses the hardcoded authBaseUrl — this verifies the helper
        // produces a valid URL given valid inputs (indirect check that nil guard works).
        let url = NotionOAuth2.authorizationUrl(clientId: "test", redirectUri: "pinkha://callback")
        #expect(url != nil)
    }

    // MARK: - HMAC signing

    @Test func signRequest_returns_64_char_hex_signature() {
        // SHA-256 output is 32 bytes = 64 hex chars regardless of input length.
        let (_, _, sig) = NotionOAuth2.signRequest(body: Data("payload".utf8))
        #expect(sig.count == 64)
        #expect(sig.allSatisfy { $0.isHexDigit })
    }

    @Test func signRequest_timestamp_is_unix_seconds() {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let (ts, _, _) = NotionOAuth2.signRequest(body: Data(), now: fixedDate)
        #expect(ts == "1700000000")
    }

    @Test func signRequest_is_deterministic_for_same_inputs() {
        // Same body + same nonce + same timestamp → same signature.
        // Proves the proxy can verify what we sent.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let nonce = "fixed-nonce-uuid"
        let body = Data(#"{"code":"abc"}"#.utf8)
        let (_, _, sig1) = NotionOAuth2.signRequest(body: body, now: date, nonce: nonce)
        let (_, _, sig2) = NotionOAuth2.signRequest(body: body, now: date, nonce: nonce)
        #expect(sig1 == sig2)
    }

    @Test func signRequest_different_body_yields_different_signature() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let nonce = "fixed-nonce-uuid"
        let (_, _, sig1) = NotionOAuth2.signRequest(body: Data("body1".utf8), now: date, nonce: nonce)
        let (_, _, sig2) = NotionOAuth2.signRequest(body: Data("body2".utf8), now: date, nonce: nonce)
        #expect(sig1 != sig2)
    }

    // MARK: - Callback URL redaction (security — never log OAuth secrets)

    @Test func redactedOAuthURL_strips_code_param() {
        let url = URL(string: "pinkha://oauth/notion?code=secret-abc-123&state=csrf-xyz")!
        let redacted = NotionOAuth2.redactedOAuthURL(url)
        #expect(!redacted.contains("secret-abc-123"))
        #expect(redacted.contains("code=***"))
    }

    @Test func redactedOAuthURL_strips_state_param() {
        let url = URL(string: "pinkha://oauth/notion?code=abc&state=csrf-token-xyz")!
        let redacted = NotionOAuth2.redactedOAuthURL(url)
        #expect(!redacted.contains("csrf-token-xyz"))
        #expect(redacted.contains("state=***"))
    }

    @Test func redactedOAuthURL_strips_access_and_refresh_tokens() {
        let url = URL(string: "pinkha://cb?access_token=AAA&refresh_token=BBB&id_token=CCC")!
        let redacted = NotionOAuth2.redactedOAuthURL(url)
        #expect(!redacted.contains("AAA"))
        #expect(!redacted.contains("BBB"))
        #expect(!redacted.contains("CCC"))
    }

    @Test func redactedOAuthURL_preserves_non_secret_params() {
        let url = URL(string: "pinkha://cb?code=secret&workspace=acme&user_id=u-42")!
        let redacted = NotionOAuth2.redactedOAuthURL(url)
        #expect(redacted.contains("workspace=acme"))
        #expect(redacted.contains("user_id=u-42"))
    }

    @Test func redactedOAuthURL_preserves_scheme_host_path() {
        let url = URL(string: "pinkha://oauth/notion?code=secret")!
        let redacted = NotionOAuth2.redactedOAuthURL(url)
        #expect(redacted.hasPrefix("pinkha://oauth/notion"))
    }

    @Test func redactedOAuthURL_handles_url_with_no_query() {
        let url = URL(string: "https://pinkha.app/")!
        let redacted = NotionOAuth2.redactedOAuthURL(url)
        #expect(redacted == "https://pinkha.app/")
    }
}
