// ABOUTME: The RFC 8414 authorization-server metadata the app reads from /.well-known.
// ABOUTME: Only the endpoints the app actually calls; the rest of the document is ignored.

import Foundation

/// The subset of RFC 8414 metadata the app needs (SPEC 5.1).
///
/// The app discovers endpoints rather than hardcoding paths so a server behind
/// a reverse proxy, or one that moves its OAuth mount, still works. Fields the
/// app never uses (`jwks_uri`, supported-algorithms lists) are dropped: the app
/// never validates tokens, it only presents them.
public struct OAuthServerMetadata: Sendable, Equatable, Decodable {
    public let issuer: String
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let registrationEndpoint: URL

    public init(
        issuer: String,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        registrationEndpoint: URL
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
    }

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
    }

    /// The well-known path (RFC 8414 §3), appended so a base URL under a subpath
    /// still resolves.
    public static func discoveryURL(baseURL: URL) -> URL {
        baseURL.appending(path: ".well-known/oauth-authorization-server")
    }
}
