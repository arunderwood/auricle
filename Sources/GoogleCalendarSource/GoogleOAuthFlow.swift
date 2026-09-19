import CalendarInterface
import Core
import CryptoKit
import Foundation

/// The OAuth 2.0 client registration the flow authenticates as. A Desktop-type
/// client may be issued a secret and a loopback client may have none, so the
/// secret is optional and sent only when present.
public struct GoogleOAuthClient: Sendable {
    public let clientID: String
    public let clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

struct AccessTokenGrant: Sendable {
    let accessToken: String
    let expiresIn: TimeInterval
}

struct AuthorizationGrant: Sendable {
    let access: AccessTokenGrant
    let refreshToken: String
}

/// PKCE (RFC 7636) and `state` primitives. The verifier is 32 random bytes
/// base64url-encoded: 43 characters, all from the RFC's unreserved alphabet.
enum PKCE {
    static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0 ..< byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    static func makeVerifier() -> String {
        randomURLSafeString(byteCount: 32)
    }

    /// `S256`: base64url of the SHA-256 of the verifier's ASCII bytes.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The installed-application OAuth 2.0 flow with PKCE and a `127.0.0.1`
/// loopback redirect (NFR-S6). Google's device-code flow is not an option
/// here: it does not permit the Calendar scope.
///
/// This type talks OAuth and nothing else: it neither reads nor writes
/// Keychain. `GoogleCalendarSource` owns where the refresh token lives.
struct GoogleOAuthFlow: Sendable {
    typealias BrowserOpener = @Sendable (URL) async throws -> Void

    static let calendarReadonlyScope = "https://www.googleapis.com/auth/calendar.readonly"

    let client: GoogleOAuthClient
    let endpoints: GoogleEndpoints
    let session: URLSession
    let openBrowser: BrowserOpener
    let redirectTimeout: Duration

    private let log = Log(category: "google-calendar")

    // MARK: - Authorization

    /// Runs the whole interactive flow: listen on an ephemeral loopback port,
    /// send the user to Google, wait for the redirect, then trade the code
    /// (with the PKCE verifier) for tokens. The listener is closed on every
    /// path out of this function.
    func authorize() async throws -> AuthorizationGrant {
        let verifier = PKCE.makeVerifier()
        let state = PKCE.randomURLSafeString(byteCount: 32)

        let listener: LoopbackRedirectListener
        do {
            listener = try LoopbackRedirectListener()
        } catch {
            throw CalendarError.authorizationFailed(reason: "the local redirect listener could not be created")
        }
        defer { listener.cancel() }

        let port: UInt16
        do {
            port = try await listener.start()
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw CalendarError.authorizationFailed(reason: "the local redirect listener could not start")
        }

        let redirectURI = "http://127.0.0.1:\(port)"
        let authorizationURL = Self.authorizationURL(
            endpoint: endpoints.authorization,
            clientID: client.clientID,
            redirectURI: redirectURI,
            codeChallenge: PKCE.challenge(for: verifier),
            state: state,
        )

        do {
            try await openBrowser(authorizationURL)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw CalendarError.authorizationFailed(reason: "the browser could not be opened")
        }

        let redirect = try await awaitRedirect(from: listener)
        let code = try Self.authorizationCode(from: redirect, expectedState: state)
        return try await exchange(code: code, verifier: verifier, redirectURI: redirectURI)
    }

    static func authorizationURL(endpoint: URL, clientID: String, redirectURI: String, codeChallenge: String, state: String) -> URL {
        let query = formEncoded([
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("response_type", "code"),
            ("scope", calendarReadonlyScope),
            ("code_challenge", codeChallenge),
            ("code_challenge_method", "S256"),
            ("state", state),
            ("access_type", "offline"),
            // Without this Google issues a refresh token only on the very
            // first consent, so re-authorizing after a revocation would
            // return none.
            ("prompt", "consent"),
        ])
        let separator = endpoint.query == nil ? "?" : "&"
        return URL(string: endpoint.absoluteString + separator + query)!
    }

    private func awaitRedirect(from listener: LoopbackRedirectListener) async throws -> [URLQueryItem] {
        let timeout = redirectTimeout
        let redirect: [URLQueryItem]? = try await withThrowingTaskGroup(of: [URLQueryItem]?.self) { group in
            group.addTask { try await listener.nextRedirect() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        guard let redirect else {
            throw CalendarError.authorizationFailed(reason: "no response arrived from the browser before the timeout")
        }
        return redirect
    }

    private static func authorizationCode(from redirect: [URLQueryItem], expectedState: String) throws -> String {
        func value(_ name: String) -> String? {
            redirect.first { $0.name == name }?.value
        }

        guard value("state") == expectedState else {
            throw CalendarError.authorizationFailed(reason: "the authorization response did not match this request")
        }
        if let error = value("error") {
            throw CalendarError.authorizationFailed(reason: error == "access_denied"
                ? "authorization was declined"
                : "authorization was rejected (\(sanitizedErrorCode(error)))")
        }
        guard let code = value("code"), !code.isEmpty else {
            throw CalendarError.authorizationFailed(reason: "the authorization response carried no code")
        }
        return code
    }

    // MARK: - Token endpoint

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> AuthorizationGrant {
        let response = try await postToken([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI),
        ])
        guard (200 ..< 300).contains(response.status) else {
            throw Self.failure(
                status: response.status,
                body: response.body,
                invalidGrant: .authorizationFailed(reason: "Google rejected the authorization code"),
            )
        }

        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: response.body) else {
            throw CalendarError.malformedResponse
        }
        let grantedScopes = (token.scope ?? "").split(separator: " ").map(String.init)
        guard grantedScopes.contains(Self.calendarReadonlyScope) else {
            throw CalendarError.authorizationFailed(reason: "Google did not grant read-only calendar access")
        }
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw CalendarError.authorizationFailed(reason: "Google returned no refresh token")
        }
        return AuthorizationGrant(
            access: AccessTokenGrant(accessToken: token.accessToken, expiresIn: TimeInterval(token.expiresIn)),
            refreshToken: refreshToken,
        )
    }

    /// Trades a refresh token for a new access token. `invalid_grant` (the
    /// token was revoked or has expired) becomes `.authorizationExpired`.
    func refresh(refreshToken: String) async throws -> AccessTokenGrant {
        let response = try await postToken([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
        guard (200 ..< 300).contains(response.status) else {
            throw Self.failure(status: response.status, body: response.body, invalidGrant: .authorizationExpired)
        }

        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: response.body) else {
            throw CalendarError.malformedResponse
        }
        return AccessTokenGrant(accessToken: token.accessToken, expiresIn: TimeInterval(token.expiresIn))
    }

    /// Sends the client credentials with every token request, adding the
    /// secret only when the client has one.
    private func postToken(_ fields: [(String, String)]) async throws -> (status: Int, body: Data) {
        var pairs = fields
        pairs.append(("client_id", client.clientID))
        if let secret = client.clientSecret {
            pairs.append(("client_secret", secret))
        }

        var request = URLRequest(url: endpoints.token)
        request.httpMethod = "POST"
        request.httpBody = Data(Self.formEncoded(pairs).utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await GoogleTransport.perform(request, using: session)
        log.info("google token request answered", ["statusCode": .publicSafe(response.status)])
        return response
    }

    /// `invalidGrant` is passed in because the same `invalid_grant` answer
    /// means different things: a stale refresh token during a refresh, but a
    /// bad or reused code during the authorization exchange.
    private static func failure(status: Int, body: Data, invalidGrant: CalendarError) -> CalendarError {
        if status == 429 {
            return .rateLimited
        }
        if (500 ... 599).contains(status) {
            return .unreachable
        }

        let code = (try? JSONDecoder().decode(TokenErrorResponse.self, from: body))?.error
        if code == "invalid_grant" {
            return invalidGrant
        }
        return .authorizationFailed(reason: "Google rejected the token request (\(code.map(sanitizedErrorCode) ?? "HTTP \(status)"))")
    }

    /// Error codes are a small lowercase vocabulary (`invalid_client`, ...).
    /// Anything else is not echoed, so a hostile or garbled body can't put
    /// arbitrary text into an error reason.
    private static func sanitizedErrorCode(_ code: String) -> String {
        let isPlainCode = !code.isEmpty && code.count <= 64 && code.allSatisfy { $0 == "_" || ($0.isASCII && $0.isLowercase) }
        return isPlainCode ? code : "unrecognized error"
    }

    // MARK: - Encoding

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~",
    )

    /// `application/x-www-form-urlencoded` with only RFC 3986 unreserved
    /// characters left literal, so a `+`, `&` or `=` inside a value can never
    /// be misread as syntax.
    static func formEncoded(_ pairs: [(String, String)]) -> String {
        pairs
            .map { name, value in
                let encodedName = name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
                return "\(encodedName)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

private struct TokenErrorResponse: Decodable {
    let error: String?
}
