import AuthenticationServices
import SwiftUI

/// Handles the Notion OAuth2 authorization code flow via ASWebAuthenticationSession.
/// Credentials must be configured before use — see constants below.
@MainActor
final class NotionOAuth2: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {

    // MARK: - Configuration (fill in once you have a public Notion integration)

    static let clientId    = ""          // e.g. "abc123"
    static let redirectUri = "pinkha://oauth/notion"
    static let authBaseUrl = "https://api.notion.com/v1/oauth/authorize"

    @Published var token: String?
    @Published var isLoading = false
    @Published var error: String?

    /// Builds the Notion OAuth2 authorization URL for the given client ID and redirect URI.
    /// Extracted as a static helper so it can be unit-tested without launching an authentication session.
    static func authorizationUrl(clientId: String, redirectUri: String) -> URL? {
        var comps = URLComponents(string: authBaseUrl)
        comps?.queryItems = [
            .init(name: "client_id",     value: clientId),
            .init(name: "response_type", value: "code"),
            .init(name: "owner",         value: "user"),
            .init(name: "redirect_uri",  value: redirectUri),
        ]
        return comps?.url
    }

    func authorize() async {
        // Build the authorization URL.
        guard !Self.clientId.isEmpty else {
            error = "Notion client ID not configured."
            return
        }
        guard let url = Self.authorizationUrl(clientId: Self.clientId, redirectUri: Self.redirectUri) else { return }

        isLoading = true
        error = nil

        do {
            let callbackUrl = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: "pinkha"
                ) { url, err in
                    if let err { cont.resume(throwing: err) }
                    else if let url { cont.resume(returning: url) }
                    else { cont.resume(throwing: URLError(.cancelled)) }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                session.start()
            }
            // Exchange the authorization code for an access token.
            guard let code = URLComponents(url: callbackUrl, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value else {
                throw URLError(.badURL)
            }
            token = try await exchangeCode(code)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Must be called from a nonisolated context; safe because UIApplication usage
        // is dispatched synchronously on the main thread via DispatchQueue.main.sync.
        var anchor = ASPresentationAnchor()
        DispatchQueue.main.sync {
            anchor = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
        return anchor
    }

    // MARK: - Token exchange

    /// Endpoint of a backend proxy that holds the Notion `client_secret` and
    /// forwards the authorization-code exchange. **Must never be the public
    /// Notion token endpoint with the secret embedded client-side** — a
    /// secret shipped in an App Store binary is trivially extractable.
    /// Empty means OAuth2 is not configured; the manual integration-token
    /// flow remains available.
    static let tokenProxyUrl = ""

    /// Errors specific to the OAuth2 flow.
    enum OAuthError: LocalizedError {
        case proxyNotConfigured
        var errorDescription: String? {
            switch self {
            case .proxyNotConfigured:
                return "OAuth2 backend proxy is not configured. Use the manual integration token field, or set NotionOAuth2.tokenProxyUrl to your server endpoint."
            }
        }
    }

    private func exchangeCode(_ code: String) async throws -> String {
        // Client secrets must never live in an iOS app binary. The exchange goes
        // through a backend proxy that holds the secret and returns the access
        // token. Left unconfigured by default — flow is opt-in.
        guard !Self.tokenProxyUrl.isEmpty,
              let proxyEndpoint = URL(string: Self.tokenProxyUrl) else {
            throw OAuthError.proxyNotConfigured
        }
        var req = URLRequest(url: proxyEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "code":         code,
            "redirect_uri": Self.redirectUri,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let accessToken = json?["access_token"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return accessToken
    }
}
