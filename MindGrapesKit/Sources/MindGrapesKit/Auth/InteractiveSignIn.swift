// ABOUTME: The interactive sign-in coordinator: PKCE + state, open the consent sheet, exchange the code.
// ABOUTME: The sheet itself is a seam (OAuthWebAuthenticating) so everything but the real UI is loop-tested.

import Foundation

/// The consent sheet, abstracted so the coordinator can be tested without UI.
///
/// The app conforms to this with an `ASWebAuthenticationSession`; a test conforms
/// with a fake that scripts the callback. The real presentation cannot live in
/// `MindGrapesKit` regardless: the package builds for watchOS, where
/// `AuthenticationServices` sign-in is unavailable.
public protocol OAuthWebAuthenticating: Sendable {
    /// Presents `url` and returns the callback URL the server redirects to on
    /// `callbackScheme`. Throws ``AuthError/signInCancelled`` when the user
    /// dismisses the sheet.
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// Runs the interactive half of OAuth (SPEC 5.2): the part `AuthManager` leaves
/// to the app because it needs a consent sheet. `AuthManager` still owns every
/// security-bearing step — PKCE, `state` validation, the token exchange — so
/// this coordinator only sequences them and parses the callback.
public struct InteractiveSignIn: Sendable {
    private let auth: AuthManager
    private let web: any OAuthWebAuthenticating

    public init(auth: AuthManager, web: any OAuthWebAuthenticating) {
        self.auth = auth
        self.web = web
    }

    /// DCR (once) → PKCE + `state` → authorization URL → consent sheet → parse
    /// the callback → exchange the code. Tokens are persisted by `exchange` on
    /// success; nothing is stored on any failure.
    public func run(asOf now: Date = Date()) async throws {
        try await auth.registerIfNeeded()
        let pkce = PKCE.random()
        let state = AuthManager.makeState()
        let authURL = try await auth.authorizationURL(pkce: pkce, state: state)
        let callback = try await web.authenticate(url: authURL, callbackScheme: auth.callbackScheme)
        let parsed = try Self.parseCallback(callback)
        try await auth.exchange(
            code: parsed.code,
            state: parsed.state,
            expectedState: state,
            pkce: pkce,
            asOf: now
        )
    }

    /// Pulls the `code` and `state` out of the redirect (RFC 6749 §4.1.2). An
    /// `error` parameter is a denied or failed authorization; a callback missing
    /// either `code` or `state` is malformed. The `state` is only carried here;
    /// it is validated in `AuthManager.exchange`, which is where the check must
    /// live so the sheet code cannot skip it.
    static func parseCallback(_ url: URL) throws -> (code: String, state: String) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let error = value("error") {
            throw AuthError.authorizationFailed(error)
        }
        guard let code = value("code"), let state = value("state") else {
            throw AuthError.malformedResponse
        }
        return (code, state)
    }
}
