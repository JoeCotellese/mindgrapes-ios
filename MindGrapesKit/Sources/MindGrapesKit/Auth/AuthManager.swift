// ABOUTME: The app's OAuth 2.1 client: DCR, PKCE code exchange, and single-refresher token refresh.
// ABOUTME: A plain actor with no locking, because SPEC 5.4 removes the refresh race instead of guarding it.

import Foundation

/// The one process that ever calls `/oauth/token` (SPEC 5.4).
///
/// Extensions read the shared Keychain through ``TokenReader`` and never
/// refresh, so no two refreshes are ever in flight and the server never sees a
/// rotated refresh token replayed. That is why this is a plain actor with no
/// mutex and no re-read-after-acquire: there is no contended section, only
/// single-threaded refresh within one process.
///
/// The interactive consent sheet is item 10. This type builds the authorization
/// URL and consumes the returned `code`; opening the `ASWebAuthenticationSession`
/// is the app's job.
public actor AuthManager {
    private let session: URLSession
    private let store: TokenStore
    private let metadata: OAuthServerMetadata
    private let redirectURI: String
    private let clientName: String

    public init(
        session: URLSession,
        store: TokenStore,
        metadata: OAuthServerMetadata,
        redirectURI: String = "net.cotellese.mindgrapes:/oauth-callback",
        clientName: String = "MindGrapes iOS"
    ) {
        self.session = session
        self.store = store
        self.metadata = metadata
        self.redirectURI = redirectURI
        self.clientName = clientName
    }

    // MARK: - Discovery

    /// Fetches the RFC 8414 metadata for a server (SPEC 5.1 step 2). Static
    /// because it runs before an `AuthManager` exists: its result is what the
    /// caller hands to `init`.
    public static func discoverMetadata(baseURL: URL, session: URLSession) async throws -> OAuthServerMetadata {
        let url = OAuthServerMetadata.discoveryURL(baseURL: baseURL)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError {
            throw AuthError.transport(error.code)
        }
        guard let http = response as? HTTPURLResponse else { throw AuthError.malformedResponse }
        guard (200...299).contains(http.statusCode) else {
            throw AuthError.metadataUnavailable(status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(OAuthServerMetadata.self, from: data)
        } catch {
            throw AuthError.malformedResponse
        }
    }

    // MARK: - Registration (DCR)

    /// Registers this device as a public client and persists the `client_id`,
    /// or returns the stored one. DCR is not repeated once registered: re-auth
    /// reuses the `client_id` (SPEC 5.3).
    @discardableResult
    public func registerIfNeeded() async throws -> String {
        if let existing = try store.clientID() { return existing }

        var request = URLRequest(url: metadata.registrationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RegistrationRequest(clientName: clientName, redirectURIs: [redirectURI])
        )

        let (data, http) = try await send(request)
        guard (200...299).contains(http.statusCode) else {
            throw AuthError.registrationFailed(status: http.statusCode)
        }
        let decoded = try decode(RegistrationResponse.self, from: data)
        try store.setClientID(decoded.clientID)
        return decoded.clientID
    }

    // MARK: - Authorization URL (opened by item 10)

    /// A CSPRNG `state` for one authorization request (SPEC 5.1 step 4).
    ///
    /// 24 random bytes (192 bits), base64url so it survives the query without
    /// re-encoding. The caller keeps this, passes it to ``authorizationURL(pkce:state:)``,
    /// and hands it back to ``exchange(code:state:expectedState:pkce:asOf:)`` as
    /// `expectedState`, where a mismatch is rejected. The RNG is injected for
    /// reproducible tests.
    public static func makeState(using rng: inout some RandomNumberGenerator) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(24)
        for _ in 0..<24 { bytes.append(rng.next()) }
        return PKCE.base64URLNoPadding(Data(bytes))
    }

    public static func makeState() -> String {
        var generator = SystemRandomNumberGenerator()
        return makeState(using: &generator)
    }

    /// Builds the `/oauth/authorize` URL for the consent sheet. Pure: no
    /// network, so item 10 can drive the sheet and hand the `code` back to
    /// ``exchange(code:state:expectedState:pkce:asOf:)``.
    ///
    /// The caller must generate `state` with ``makeState()`` and later pass the
    /// same value as `expectedState` to `exchange`. State verification is not
    /// optional: `exchange` requires it, so a caller cannot complete the flow
    /// without it.
    public func authorizationURL(pkce: PKCE, state: String) throws -> URL {
        guard let clientID = try store.clientID() else { throw AuthError.notRegistered }
        guard var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw AuthError.malformedResponse
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { throw AuthError.malformedResponse }
        return url
    }

    // MARK: - Code exchange

    /// Exchanges an authorization code for the token pair and persists it
    /// (SPEC 5.1 step 5). `now` stamps the access-token expiry from `expires_in`.
    ///
    /// `returnedState` is the `state` from the callback URL; `expectedState` is
    /// what ``makeState()`` produced for this request. They must match, or the
    /// code is rejected before the token endpoint is touched: this is where the
    /// SPEC 5.1 `state` check lives, so it cannot be skipped by the sheet code.
    public func exchange(
        code: String,
        state returnedState: String,
        expectedState: String,
        pkce: PKCE,
        asOf now: Date = Date()
    ) async throws {
        guard returnedState == expectedState else { throw AuthError.stateMismatch }
        guard let clientID = try store.clientID() else { throw AuthError.notRegistered }
        let tokens = try await tokenRequest(
            [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectURI,
                "client_id": clientID,
                "code_verifier": pkce.verifier,
            ],
            asOf: now
        )
        try store.setTokens(tokens)
    }

    // MARK: - Refresh

    /// Refreshes proactively when the access token has less than the lead time
    /// left, otherwise returns the stored bearer as-is. The main entry the
    /// upload path calls before a request.
    public func validAccessToken(asOf now: Date = Date()) async throws -> String {
        guard let tokens = try store.tokens() else { throw AuthError.noStoredTokens }
        if tokens.needsRefresh(asOf: now) {
            return try await refresh(asOf: now).accessToken
        }
        return tokens.accessToken
    }

    /// Forces one refresh and persists the rotated pair. On `invalid_grant` the
    /// stored tokens are dropped (the auth-required state, SPEC 5.3) and
    /// ``AuthError/authRequired`` is thrown; the caller must not retry.
    @discardableResult
    public func refresh(asOf now: Date = Date()) async throws -> TokenSet {
        guard let current = try store.tokens() else { throw AuthError.noStoredTokens }
        guard let clientID = try store.clientID() else { throw AuthError.notRegistered }
        let refreshed = try await tokenRequest(
            [
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "client_id": clientID,
            ],
            asOf: now
        )
        // A successful refresh has already rotated the token server-side:
        // `current.refreshToken` is now invalid. If persisting the new pair
        // fails, the stored old token must not survive, or the next refresh
        // replays it and the server reads that as theft and revokes the whole
        // family (SPEC 5.3). Dropping it forces a clean re-auth instead.
        do {
            try store.setTokens(refreshed)
        } catch {
            try? store.deleteTokens()
            throw AuthError.authRequired
        }
        return refreshed
    }

    /// Drops the credentials, keeping the registration so re-auth need not
    /// repeat DCR (SPEC 5.3).
    public func signOut() throws {
        try store.deleteTokens()
    }

    // MARK: - Token endpoint

    private func tokenRequest(_ fields: [String: String], asOf now: Date) async throws -> TokenSet {
        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(fields).utf8)

        let (data, http) = try await send(request)

        if http.statusCode == 400, isInvalidGrant(data) {
            // The refresh token is dead: revoked, or the family was tripped by a
            // replay. Drop the pair so the app reads as auth-required; do not
            // retry, which would only replay again.
            try? store.deleteTokens()
            throw AuthError.authRequired
        }
        guard (200...299).contains(http.statusCode) else {
            throw AuthError.tokenRequestFailed(status: http.statusCode)
        }

        let decoded = try decode(TokenResponse.self, from: data)
        return TokenSet(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            accessTokenExpiresAt: now.addingTimeInterval(TimeInterval(decoded.expiresIn))
        )
    }

    private func isInvalidGrant(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(OAuthErrorResponse.self, from: data))?.error == "invalid_grant"
    }

    // MARK: - Plumbing

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AuthError.malformedResponse }
            return (data, http)
        } catch let error as URLError {
            throw AuthError.transport(error.code)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AuthError.malformedResponse
        }
    }

    /// `application/x-www-form-urlencoded` with only RFC 3986 unreserved
    /// characters left literal, so an opaque refresh token containing `+` or `/`
    /// survives instead of being read as a space or a delimiter.
    private static func formEncode(_ fields: [String: String]) -> String {
        fields
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    // MARK: - Wire shapes

    private struct RegistrationRequest: Encodable {
        let clientName: String
        let redirectURIs: [String]
        enum CodingKeys: String, CodingKey {
            case clientName = "client_name"
            case redirectURIs = "redirect_uris"
        }
    }

    private struct RegistrationResponse: Decodable {
        let clientID: String
        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private struct OAuthErrorResponse: Decodable {
        let error: String
    }
}
