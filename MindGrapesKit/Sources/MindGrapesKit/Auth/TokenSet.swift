// ABOUTME: The OAuth credential triple the app stores: access token, refresh token, expiry.
// ABOUTME: Expiry decisions take the instant as an argument so they stay pure and testable.

import Foundation

/// The tokens one OAuth client holds for a Mind Grapes server (SPEC 5.3).
///
/// Written and read as a unit: an access token stored without its matching
/// expiry, or a refresh token left behind from an earlier rotation, would be
/// worse than no credential at all.
///
/// Nothing here reads the clock. `AuthManager` (item 8) decides *when* to
/// refresh, and it does so against an injected instant, so the decision can be
/// driven from a fake clock instead of by waiting.
public struct TokenSet: Sendable, Hashable, Codable {
    /// The EdDSA JWT sent as `Authorization: Bearer`. Default TTL is 600 s.
    public let accessToken: String

    /// The opaque, single-use refresh token. Rotates on every refresh, and
    /// replaying a rotated one revokes the whole family (SPEC 5.3).
    public let refreshToken: String

    /// When the access token stops being accepted, from the token response's
    /// `expires_in` at the time it was issued.
    public let accessTokenExpiresAt: Date

    /// How much life must remain before the app refreshes ahead of a request
    /// (SPEC 5.3). Only the containing app acts on this; extensions never
    /// refresh (SPEC 5.4).
    public static let refreshLeadTime: TimeInterval = 60

    public init(accessToken: String, refreshToken: String, accessTokenExpiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
    }

    /// Coding keys are the on-disk contract for the stored Keychain blob, so
    /// they are pinned: renaming a property must not strand a stored token pair
    /// and sign the user out on the next launch.
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accessTokenExpiresAt = "access_token_expires_at"
    }

    /// Whether the access token would be rejected as of `now`.
    ///
    /// Note that an expired access token is still worth sending from an
    /// extension (SPEC 5.4): the cost is one wasted round trip, and the
    /// alternative, refreshing out of process, is what trips family revocation.
    public func isAccessTokenExpired(asOf now: Date) -> Bool {
        accessTokenExpiresAt <= now
    }

    /// Whether the app should refresh before using this token.
    public func needsRefresh(
        asOf now: Date,
        leadTime: TimeInterval = TokenSet.refreshLeadTime
    ) -> Bool {
        accessTokenExpiresAt.timeIntervalSince(now) < leadTime
    }
}

// MARK: - Redaction

/// Tokens are bearer credentials: anything that renders one, including a test
/// failure message or a crash log, is a leak. Every rendering path this type
/// exposes is overridden, reflection included, since that is what test
/// frameworks and debuggers walk.
extension TokenSet: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "TokenSet(redacted, expires \(accessTokenExpiresAt.timeIntervalSince1970))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["accessTokenExpiresAt": accessTokenExpiresAt],
            displayStyle: .struct
        )
    }
}
