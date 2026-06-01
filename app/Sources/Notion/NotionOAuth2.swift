import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI

/// Handles the Notion OAuth2 authorization code flow via ASWebAuthenticationSession.
/// Credentials must be configured before use — see constants below.
@MainActor
final class NotionOAuth2: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {

    // MARK: - Configuration (fill in once you have a public Notion integration)

    /// Public Notion integration client ID. Public on purpose — it ends up in
    /// the authorize URL opened in the browser, so it's not a secret. Read at
    /// runtime from Info.plist (injected from `app/Config/Secrets.xcconfig`)
    /// so a fresh checkout doesn't need a source edit to wire OAuth up.
    static var clientId: String {
        (Bundle.main.object(forInfoDictionaryKey: "NOTION_CLIENT_ID") as? String) ?? ""
    }
    static let authBaseUrl = "https://api.notion.com/v1/oauth/authorize"

    /// Public HTTPS base URL of the notion-proxy on Railway, read at runtime
    /// from Info.plist (injected from `app/Config/Secrets.xcconfig`). Empty
    /// when the proxy is not configured yet — `OAuthError.proxyNotConfigured`
    /// is thrown in that case.
    static var proxyBaseUrl: String {
        (Bundle.main.object(forInfoDictionaryKey: "NOTION_PROXY_URL") as? String) ?? ""
    }

    /// Redirect URI sent to Notion in the authorization URL. Must be HTTPS
    /// (Notion rejects custom URL schemes since 2024). The proxy receives
    /// the callback at this URL and bounces the browser to `pinkha://oauth/notion`,
    /// which `ASWebAuthenticationSession` catches via `callbackURLScheme: "pinkha"`.
    static var redirectUri: String {
        let base = proxyBaseUrl
        return base.isEmpty ? "" : "\(base)/oauth/callback"
    }

    /// Custom URL scheme registered in Info.plist (`CFBundleURLSchemes`). The
    /// proxy redirects to `\(callbackScheme)://oauth/notion?code=...` and this
    /// session picks it up.
    static let callbackScheme = "pinkha"

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
        print("[OAuth] authorize() called — clientId='\(Self.clientId)' proxyBaseUrl='\(Self.proxyBaseUrl)'")

        // Build the authorization URL.
        guard !Self.clientId.isEmpty else {
            print("[OAuth] aborting: clientId is empty")
            error = "Notion client ID not configured."
            return
        }
        guard !Self.redirectUri.isEmpty else {
            print("[OAuth] aborting: redirectUri is empty (NOTION_PROXY_URL missing)")
            error = "Notion proxy URL not configured (NOTION_PROXY_URL)."
            return
        }
        guard let url = Self.authorizationUrl(clientId: Self.clientId, redirectUri: Self.redirectUri) else {
            print("[OAuth] aborting: failed to build authorize URL")
            return
        }
        print("[OAuth] opening ASWebAuthenticationSession url=\(url.absoluteString) callbackScheme=\(Self.callbackScheme)")

        isLoading = true
        error = nil

        do {
            let callbackUrl = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: Self.callbackScheme
                ) { url, err in
                    print("[OAuth] session completion url=\(url?.absoluteString ?? "nil") err=\(err.map(String.init(describing:)) ?? "nil")")
                    if let err { cont.resume(throwing: err) }
                    else if let url { cont.resume(returning: url) }
                    else { cont.resume(throwing: URLError(.cancelled)) }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                let started = session.start()
                print("[OAuth] session.start() returned \(started)")
                // start() returns false silently when iOS refuses the session
                // (e.g. no key window, invalid callback scheme, missing entitlement).
                // Without this guard, the continuation would never resume and the
                // Task would hang forever with no log output and no UI feedback.
                if !started {
                    cont.resume(throwing: URLError(.cannotConnectToHost))
                }
            }
            print("[OAuth] got callback url=\(callbackUrl.absoluteString)")
            // Exchange the authorization code for an access token.
            guard let code = URLComponents(url: callbackUrl, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value else {
                print("[OAuth] no `code` query item in callback URL")
                throw URLError(.badURL)
            }
            print("[OAuth] exchanging code for token via proxy")
            token = try await exchangeCode(code)
            print("[OAuth] token received, length=\(token?.count ?? 0)")
        } catch {
            print("[OAuth] failed: \(error)")
            self.error = error.localizedDescription
            Observability.capture(error)
        }
        isLoading = false
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // `ASWebAuthenticationSession` calls this on the main thread (it's the
        // standard contract for `ASWebAuthenticationPresentationContextProviding`).
        // The previous implementation used `DispatchQueue.main.sync { … }`, which
        // dead-locks immediately when invoked from the main thread — iOS 26
        // detects the deadlock and raises EXC_BREAKPOINT, crashing the app
        // before the auth WebView ever opens.
        //
        // `MainActor.assumeIsolated` runs the block synchronously when the
        // caller is already on the main actor (which we are), with a runtime
        // assertion as a safety net.
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }

    // MARK: - Token exchange

    /// Endpoint of a backend proxy that holds the Notion `client_secret` and
    /// forwards the authorization-code exchange. **Must never be the public
    /// Notion token endpoint with the secret embedded client-side** — a
    /// secret shipped in an App Store binary is trivially extractable.
    /// Derived from `proxyBaseUrl` so a single Info.plist value configures
    /// both the redirect URI and the token endpoint.
    static var tokenProxyUrl: String {
        let base = proxyBaseUrl
        return base.isEmpty ? "" : "\(base)/oauth/token"
    }

    /// Shared HMAC secret used to sign requests to `tokenProxyUrl`. Must match
    /// `PROXY_HMAC_SECRET` on the proxy. Hex-encoded, generated with
    /// `openssl rand -hex 32`. Read from Info.plist at runtime (injected from
    /// `app/Config/Secrets.xcconfig`) so the value never enters source control.
    /// Shipping it in the binary is acceptable as defense-in-depth: combined
    /// with rate-limiting and Sentry on the proxy, it raises the cost of abuse
    /// without pretending to be a strong secret.
    static var proxyHmacSecret: String {
        Bundle.main.object(forInfoDictionaryKey: "PROXY_HMAC_SECRET") as? String ?? ""
    }

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
        let body = try JSONSerialization.data(withJSONObject: [
            "code":         code,
            "redirect_uri": Self.redirectUri,
        ])
        var req = URLRequest(url: proxyEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (timestamp, nonce, signature) = Self.signRequest(body: body)
        req.setValue(timestamp, forHTTPHeaderField: "X-Pinkha-Timestamp")
        req.setValue(nonce,     forHTTPHeaderField: "X-Pinkha-Nonce")
        req.setValue(signature, forHTTPHeaderField: "X-Pinkha-Signature")
        req.httpBody = body

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

    /// Builds the (timestamp, nonce, hex-signature) tuple for a proxy request.
    /// Signature = HMAC-SHA256(secret, "<ts>\n<nonce>\n<body>") — must match
    /// the verification logic in `notion-proxy::verify_signature`.
    static func signRequest(body: Data, now: Date = Date(), nonce: String = UUID().uuidString) -> (String, String, String) {
        let timestamp = String(Int(now.timeIntervalSince1970))
        let key = SymmetricKey(data: Data(proxyHmacSecret.utf8))
        var message = Data()
        message.append(Data(timestamp.utf8))
        message.append(0x0A) // "\n"
        message.append(Data(nonce.utf8))
        message.append(0x0A)
        message.append(body)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        let signature = mac.map { String(format: "%02x", $0) }.joined()
        return (timestamp, nonce, signature)
    }
}
