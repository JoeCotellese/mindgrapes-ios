// ABOUTME: The typed failures of the OAuth flow, separating "sign in again" from "try later".
// ABOUTME: invalid_grant is its own case because it drives the queue's auth-required parking (SPEC 5.3).

import Foundation

/// Why an OAuth operation did not produce a usable token.
public enum AuthError: Error, Equatable, Sendable {
    /// A refresh returned `invalid_grant`: the token family is revoked or was
    /// tripped by a replay (SPEC 5.3). Auth is dead until the user signs in
    /// again; the queue parks rather than failing captures (SPEC 8.5). Never
    /// retried blindly.
    case authRequired

    /// The `state` returned on the OAuth callback did not match the one sent
    /// with the authorization request: a possible CSRF or a crossed flow. The
    /// code is rejected before it reaches the token endpoint.
    case stateMismatch

    /// Code exchange or refresh was attempted before Dynamic Client
    /// Registration persisted a `client_id`.
    case notRegistered

    /// Refresh or `validAccessToken` was called with no stored token pair.
    case noStoredTokens

    /// `/oauth/register` answered with a non-success status.
    case registrationFailed(status: Int)

    /// `/oauth/token` answered with a non-success status that was not
    /// `invalid_grant`.
    case tokenRequestFailed(status: Int)

    /// The metadata document could not be fetched.
    case metadataUnavailable(status: Int)

    /// A success status carried a body that was not the documented shape.
    case malformedResponse

    /// The request never got an answer: no route, timeout, TLS failure.
    case transport(URLError.Code)

    /// The user dismissed the consent sheet. Not a failure to surface loudly:
    /// the app resets quietly and the flow is retryable. The app adapter maps
    /// `ASWebAuthenticationSessionError.canceledLogin` to this (item 10).
    case signInCancelled

    /// The authorization callback carried an OAuth `error` parameter rather than
    /// a `code` (RFC 6749 §4.1.2.1). The associated value is that error code,
    /// e.g. `access_denied`.
    case authorizationFailed(String)
}
