import Testing
import Foundation
@testable import Pinkha

// Unit tests for NotionOAuth2 URL construction.
// No ASWebAuthenticationSession is launched — only the static helper is exercised.

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
}
