// ABOUTME: Drives the interactive sign-in coordinator and its OAuth callback parsing (item #10).
// ABOUTME: The real ASWebAuthenticationSession is faked behind OAuthWebAuthenticating; no UI here.

import Foundation
import Testing

@testable import MindGrapesKit

// MARK: - Callback parsing (pure)

@Suite("InteractiveSignIn callback parsing")
struct InteractiveSignInCallbackTests {
    private func callback(_ query: String) -> URL {
        URL(string: "net.cotellese.mindgrapes:/oauth-callback?\(query)")!
    }

    @Test func aCodeAndStateAreReturned() throws {
        let parsed = try InteractiveSignIn.parseCallback(callback("code=abc&state=xyz"))
        #expect(parsed.code == "abc")
        #expect(parsed.state == "xyz")
    }

    @Test func anErrorParamIsAFailedAuthorization() {
        // RFC 6749 §4.1.2.1: the server reports a denial as error=.
        let error = #expect(throws: AuthError.self) {
            try InteractiveSignIn.parseCallback(callback("error=access_denied&state=xyz"))
        }
        #expect(error == .authorizationFailed("access_denied"))
    }

    @Test func aMissingCodeIsMalformed() {
        let error = #expect(throws: AuthError.self) {
            try InteractiveSignIn.parseCallback(callback("state=xyz"))
        }
        #expect(error == .malformedResponse)
    }

    @Test func aMissingStateIsMalformed() {
        let error = #expect(throws: AuthError.self) {
            try InteractiveSignIn.parseCallback(callback("code=abc"))
        }
        #expect(error == .malformedResponse)
    }
}

// MARK: - Orchestration (scripted)

/// Scripts the consent sheet without UI: given the authorization URL, returns a
/// callback URL (or throws). The happy-path fake echoes the `state` it was sent,
/// which is what a correct server does.
private struct FakeWebAuth: OAuthWebAuthenticating {
    let respond: @Sendable (URL) throws -> URL
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try respond(url)
    }
}

private func state(from authorizationURL: URL) -> String {
    URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "state" }?.value ?? ""
}

private func callbackURL(query: String) -> URL {
    URL(string: "net.cotellese.mindgrapes:/oauth-callback?\(query)")!
}

/// Serialized because `SignInStubURLProtocol` scripts answers through
/// process-global state.
@Suite("InteractiveSignIn orchestration", .serialized)
struct InteractiveSignInOrchestrationTests {
    private let base = URL(string: "https://brain.example")!
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private var metadata: OAuthServerMetadata {
        OAuthServerMetadata(
            issuer: "https://brain.example",
            authorizationEndpoint: base.appending(path: "oauth/authorize"),
            tokenEndpoint: base.appending(path: "oauth/token"),
            registrationEndpoint: base.appending(path: "oauth/register")
        )
    }

    private func make(web: some OAuthWebAuthenticating) -> (InteractiveSignIn, TokenStore) {
        let store = TokenStore(keychain: InMemoryKeychain(), accessGroup: "test.group")
        let auth = AuthManager(session: SignInStubURLProtocol.makeSession(), store: store, metadata: metadata)
        return (InteractiveSignIn(auth: auth, web: web), store)
    }

    /// DCR answers a client_id; the token endpoint answers a pair.
    private func installEndpoints() {
        SignInStubURLProtocol.install { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/oauth/register") {
                body = #"{"client_id":"client-abc"}"#
            } else if path.hasSuffix("/oauth/token") {
                body = #"{"access_token":"at-1","refresh_token":"rt-1","expires_in":600}"#
            } else {
                return .failure(URLError(.unsupportedURL))
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return .success((http, Data(body.utf8)))
        }
    }

    @Test func aCompletedConsentRegistersAndPersistsTokens() async throws {
        defer { SignInStubURLProtocol.reset() }
        installEndpoints()
        let web = FakeWebAuth { authURL in
            callbackURL(query: "code=auth-code&state=\(state(from: authURL))")
        }
        let (signIn, store) = make(web: web)

        try await signIn.run(asOf: now)

        #expect(try store.clientID() == "client-abc")
        #expect(try store.tokens()?.accessToken == "at-1")
        #expect(try store.tokens()?.refreshToken == "rt-1")
    }

    @Test func aMismatchedStateIsRejectedAndStoresNoTokens() async throws {
        // The state check lives in exchange; a callback carrying the wrong state
        // must not reach a stored token pair.
        defer { SignInStubURLProtocol.reset() }
        installEndpoints()
        let web = FakeWebAuth { _ in callbackURL(query: "code=auth-code&state=not-the-state") }
        let (signIn, store) = make(web: web)

        let error = await #expect(throws: AuthError.self) { try await signIn.run(asOf: now) }
        #expect(error == .stateMismatch)
        #expect(try store.tokens() == nil)
    }

    @Test func aCancelledSheetPropagatesAndStoresNoTokens() async throws {
        defer { SignInStubURLProtocol.reset() }
        installEndpoints()
        let web = FakeWebAuth { _ in throw AuthError.signInCancelled }
        let (signIn, store) = make(web: web)

        let error = await #expect(throws: AuthError.self) { try await signIn.run(asOf: now) }
        #expect(error == .signInCancelled)
        #expect(try store.tokens() == nil)
    }

    @Test func aDeniedAuthorizationSurfacesAndStoresNoTokens() async throws {
        defer { SignInStubURLProtocol.reset() }
        installEndpoints()
        let web = FakeWebAuth { _ in callbackURL(query: "error=access_denied&state=whatever") }
        let (signIn, store) = make(web: web)

        let error = await #expect(throws: AuthError.self) { try await signIn.run(asOf: now) }
        #expect(error == .authorizationFailed("access_denied"))
        #expect(try store.tokens() == nil)
    }

    @Test func theCallbackSchemeComesFromTheRedirectURI() {
        // Pins the derive-from-redirectURI so the sheet's scheme cannot drift
        // from the redirect_uri that DCR registers and authorize sends.
        let store = TokenStore(keychain: InMemoryKeychain(), accessGroup: "test.group")
        let auth = AuthManager(session: SignInStubURLProtocol.makeSession(), store: store, metadata: metadata)
        #expect(auth.callbackScheme == "net.cotellese.mindgrapes")
    }
}
