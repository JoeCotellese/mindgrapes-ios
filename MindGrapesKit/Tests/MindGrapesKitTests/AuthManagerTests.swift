// ABOUTME: Drives AuthManager's DCR, code exchange, and refresh against a scripted token endpoint.
// ABOUTME: Serialized because StubURLProtocol's handler is process-global; uses a fake clock, no waiting.

import Foundation
import Testing

@testable import MindGrapesKit

/// Records the paths the stub was asked for, so a test can assert a call was, or
/// was not, made. `@unchecked Sendable` with a lock because the stub handler is
/// `@Sendable`.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func record(_ path: String) { lock.withLock { paths.append(path) } }
    var recorded: [String] { lock.withLock { paths } }
}

@Suite(.serialized)
struct AuthManagerTests {
    private let base = URL(string: "https://brain.example")!

    private var metadata: OAuthServerMetadata {
        OAuthServerMetadata(
            issuer: "https://brain.example",
            authorizationEndpoint: base.appending(path: "oauth/authorize"),
            tokenEndpoint: base.appending(path: "oauth/token"),
            registrationEndpoint: base.appending(path: "oauth/register")
        )
    }

    private func makeManager() -> (AuthManager, TokenStore) {
        let store = TokenStore(keychain: InMemoryKeychain(), accessGroup: "test.group")
        let manager = AuthManager(session: AuthStubURLProtocol.makeSession(), store: store, metadata: metadata)
        return (manager, store)
    }

    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Discovery

    @Test func discoverMetadataParsesWellKnown() async throws {
        defer { AuthStubURLProtocol.reset() }
        AuthStubURLProtocol.install(status: 200, text: """
        {"issuer":"https://brain.example",
         "authorization_endpoint":"https://brain.example/oauth/authorize",
         "token_endpoint":"https://brain.example/oauth/token",
         "registration_endpoint":"https://brain.example/oauth/register"}
        """)
        let md = try await AuthManager.discoverMetadata(baseURL: base, session: AuthStubURLProtocol.makeSession())
        #expect(md.tokenEndpoint.absoluteString == "https://brain.example/oauth/token")
        #expect(md.registrationEndpoint.absoluteString == "https://brain.example/oauth/register")
    }

    // MARK: - Registration

    @Test func registerPersistsClientIDAndDoesNotRepeat() async throws {
        defer { AuthStubURLProtocol.reset() }
        let (manager, store) = makeManager()
        AuthStubURLProtocol.install(status: 200, text: #"{"client_id":"client-123"}"#)

        let id = try await manager.registerIfNeeded()
        #expect(id == "client-123")
        #expect(try store.clientID() == "client-123")

        // Re-auth reuses the registration (SPEC 5.3): a second call must not hit
        // the network, so a now-failing transport would surface if it did.
        AuthStubURLProtocol.installTransportFailure(.notConnectedToInternet)
        #expect(try await manager.registerIfNeeded() == "client-123")
    }

    @Test func registrationFailureSurfacesTheStatus() async throws {
        defer { AuthStubURLProtocol.reset() }
        let (manager, _) = makeManager()
        AuthStubURLProtocol.install(status: 503, text: "unavailable")
        await #expect(throws: AuthError.registrationFailed(status: 503)) {
            try await manager.registerIfNeeded()
        }
    }

    // MARK: - Authorization URL

    @Test func authorizationURLCarriesPKCEChallengeAndState() async throws {
        let (manager, store) = makeManager()
        try store.setClientID("client-123")
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")

        let url = try await manager.authorizationURL(pkce: pkce, state: "state-xyz")
        let items = Dictionary(
            uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value) }
        )
        #expect(items["response_type"] == "code")
        #expect(items["client_id"] == "client-123")
        #expect(items["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "state-xyz")
        #expect(items["redirect_uri"] == "net.cotellese.mindgrapes:/oauth-callback")
    }

    @Test func authorizationURLRequiresRegistration() async throws {
        let (manager, _) = makeManager()
        await #expect(throws: AuthError.notRegistered) {
            try await manager.authorizationURL(pkce: PKCE(verifier: "v"), state: "s")
        }
    }

    // MARK: - Code exchange

    @Test func exchangePersistsTokensWithExpiryFromExpiresIn() async throws {
        defer { AuthStubURLProtocol.reset() }
        let (manager, store) = makeManager()
        try store.setClientID("client-123")
        AuthStubURLProtocol.install(status: 200, text: #"{"access_token":"at-1","refresh_token":"rt-1","expires_in":600}"#)

        try await manager.exchange(code: "auth-code", pkce: PKCE(verifier: "verifier"), asOf: now)

        let tokens = try #require(try store.tokens())
        #expect(tokens.accessToken == "at-1")
        #expect(tokens.refreshToken == "rt-1")
        #expect(tokens.accessTokenExpiresAt == now.addingTimeInterval(600))
    }

    @Test func exchangeRequiresRegistration() async throws {
        let (manager, _) = makeManager()
        await #expect(throws: AuthError.notRegistered) {
            try await manager.exchange(code: "c", pkce: PKCE(verifier: "v"), asOf: now)
        }
    }

    // MARK: - validAccessToken and refresh

    @Test func validAccessTokenReturnsStoredWhenFresh() async throws {
        defer { AuthStubURLProtocol.reset() }
        let (manager, store) = makeManager()
        try store.setClientID("c")
        try store.setTokens(TokenSet(accessToken: "at-fresh", refreshToken: "rt", accessTokenExpiresAt: now.addingTimeInterval(600)))
        // A fresh token must not trigger a refresh; a failing transport proves it.
        AuthStubURLProtocol.installTransportFailure(.notConnectedToInternet)

        #expect(try await manager.validAccessToken(asOf: now) == "at-fresh")
    }

    @Test func validAccessTokenRefreshesWithinLeadTime() async throws {
        defer { AuthStubURLProtocol.reset() }
        let (manager, store) = makeManager()
        try store.setClientID("c")
        // 30 s left, under the 60 s lead time (SPEC 5.3) → refresh.
        try store.setTokens(TokenSet(accessToken: "at-old", refreshToken: "rt-old", accessTokenExpiresAt: now.addingTimeInterval(30)))
        AuthStubURLProtocol.install(status: 200, text: #"{"access_token":"at-new","refresh_token":"rt-new","expires_in":600}"#)

        #expect(try await manager.validAccessToken(asOf: now) == "at-new")
        // Rotation persisted: the old refresh token must never be reused.
        #expect(try store.tokens()?.refreshToken == "rt-new")
    }

    @Test func validAccessTokenWithNoTokensThrows() async throws {
        let (manager, _) = makeManager()
        await #expect(throws: AuthError.noStoredTokens) {
            try await manager.validAccessToken(asOf: now)
        }
    }

    // MARK: - invalid_grant (SPEC 5.3)

    @Test func refreshInvalidGrantParksAuthAndDropsTokensKeepingRegistration() async throws {
        defer { AuthStubURLProtocol.reset() }
        let (manager, store) = makeManager()
        try store.setClientID("c")
        try store.setTokens(TokenSet(accessToken: "at", refreshToken: "rt", accessTokenExpiresAt: now.addingTimeInterval(10)))
        AuthStubURLProtocol.install(status: 400, text: #"{"error":"invalid_grant"}"#)

        await #expect(throws: AuthError.authRequired) { try await manager.refresh(asOf: now) }

        #expect(try store.tokens() == nil)     // dropped → auth-required state
        #expect(try store.clientID() == "c")   // registration survives; DCR not repeated
    }

    @Test func tokenEndpointServerErrorSurfacesStatusAndKeepsTokens() async throws {
        defer { AuthStubURLProtocol.reset() }
        let (manager, store) = makeManager()
        try store.setClientID("c")
        try store.setTokens(TokenSet(accessToken: "at", refreshToken: "rt", accessTokenExpiresAt: now.addingTimeInterval(10)))
        // A 500 is transient: SPEC never says the family died, so the pair must
        // survive for a later retry rather than signing the user out.
        AuthStubURLProtocol.install(status: 500, text: "boom")

        await #expect(throws: AuthError.tokenRequestFailed(status: 500)) { try await manager.refresh(asOf: now) }
        #expect(try store.tokens() != nil)
    }

    @Test func transportFailureOnRefreshSurfacesTransport() async throws {
        defer { AuthStubURLProtocol.reset() }
        let (manager, store) = makeManager()
        try store.setClientID("c")
        try store.setTokens(TokenSet(accessToken: "at", refreshToken: "rt", accessTokenExpiresAt: now.addingTimeInterval(10)))
        AuthStubURLProtocol.installTransportFailure(.timedOut)

        await #expect(throws: AuthError.transport(.timedOut)) { try await manager.refresh(asOf: now) }
        #expect(try store.tokens() != nil)
    }

    // MARK: - Single-refresher rule (SPEC 5.4)

    @Test func extensionReaderIssuesZeroTokenCallsHoweverStale() async throws {
        defer { AuthStubURLProtocol.reset() }
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain, accessGroup: "test.group")
        // A long-expired token: an extension still sends it as-is (SPEC 5.4),
        // never refreshing, because an out-of-process refresh trips family
        // revocation.
        try store.setTokens(TokenSet(accessToken: "stale", refreshToken: "rt", accessTokenExpiresAt: now.addingTimeInterval(-100)))

        let log = RequestLog()
        AuthStubURLProtocol.install { request in
            log.record(request.url!.path)
            return .failure(URLError(.badServerResponse))
        }

        let reader = TokenReader(keychain: keychain, accessGroup: "test.group")
        #expect(try reader.hasUsableAccessToken() == true)
        #expect(try reader.tokens()?.accessToken == "stale")
        #expect(log.recorded.isEmpty)
    }
}
