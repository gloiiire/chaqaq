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
    static let tokenUrl    = "https://api.notion.com/v1/oauth/token"

    @Published var token: String?
    @Published var isLoading = false
    @Published var error: String?

    func authorize() async {
        // Build the authorization URL.
        guard !Self.clientId.isEmpty else {
            error = "Notion client ID not configured."
            return
        }
        var comps = URLComponents(string: Self.authBaseUrl)!
        comps.queryItems = [
            .init(name: "client_id",     value: Self.clientId),
            .init(name: "response_type", value: "code"),
            .init(name: "owner",         value: "user"),
            .init(name: "redirect_uri",  value: Self.redirectUri),
        ]
        guard let url = comps.url else { return }

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

    private func exchangeCode(_ code: String) async throws -> String {
        // POST to Notion token endpoint — client secret must be in a secure config,
        // never hardcoded in production. Left empty here as a placeholder.
        let clientSecret = ""   // TODO: load from Keychain or server-side proxy
        guard let tokenEndpoint = URL(string: Self.tokenUrl) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let creds = Data("\(Self.clientId):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type":   "authorization_code",
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
