// ABOUTME: The Keychain-backed OAuth credential store: a read/write store plus a reader.
// ABOUTME: Extensions get the read-only type, which has no write and no refresh path (SPEC 5.4).

import Foundation

/// The Keychain items the OAuth credentials live in.
///
/// Two items, not one, because their lifetimes differ: signing out drops the
/// tokens while the registration stays, since re-auth reuses the stored
/// `client_id` and does not repeat DCR (SPEC 5.3).
enum TokenKeychainItems {
    /// Namespaced away from anything else this app might ever store in the
    /// shared group.
    static let service = "net.cotellese.mindgrapes.oauth"

    /// Account names are the on-device contract across app updates. Renaming
    /// one strands the stored credential: the read finds nothing, and the user
    /// is asked to sign in again with no visible cause.
    static func clientRegistration(accessGroup: String) -> KeychainItem {
        KeychainItem(service: service, account: "client_registration", accessGroup: accessGroup)
    }

    static func tokens(accessGroup: String) -> KeychainItem {
        KeychainItem(service: service, account: "oauth_tokens", accessGroup: accessGroup)
    }
}

/// Reading the stored OAuth credentials.
///
/// Deliberately has no counterpart for writing and no way to reach one. This is
/// the surface extensions and out-of-process intents get (SPEC 5.4).
public protocol TokenReading: Sendable {
    /// The `client_id` from Dynamic Client Registration, or `nil` before the
    /// device has registered.
    func clientID() throws -> String?

    /// The stored credentials, or `nil` when the device is not signed in.
    /// Throws on a Keychain failure rather than reporting absence.
    func tokens() throws -> TokenSet?

    /// Whether there is an access token worth sending.
    ///
    /// Expiry is intentionally not part of the answer. Per SPEC 5.4 an
    /// extension sends whatever is stored, expired or not: the cost of a stale
    /// token is one wasted round trip, while the alternative, refreshing out of
    /// process, races the app and revokes the whole token family.
    func hasUsableAccessToken() throws -> Bool
}

/// Writing the stored OAuth credentials. Only the containing app has this.
public protocol TokenWriting: Sendable {
    func setClientID(_ clientID: String) throws

    /// Replaces the stored pair. Whole-set only: an access token stored without
    /// its expiry, or a refresh token surviving a rotation it was not part of,
    /// is worse than no credential.
    func setTokens(_ tokens: TokenSet) throws

    /// Drops the credentials but keeps the registration, which is the
    /// authorization-needed state from SPEC 5.3.
    func deleteTokens() throws

    /// Drops the registration too, for disconnecting from a server entirely.
    func deleteAll() throws
}

/// The extensions' view of the shared Keychain (SPEC 5.4).
///
/// The single-refresher rule is structural, not a convention: this type
/// conforms only to ``TokenReading``, carries no writer to reach through, and
/// nothing it exposes can call the token endpoint. An extension holding one of
/// these cannot refresh even by mistake, so two refreshes can never be in
/// flight and the server never sees a rotated token replayed.
///
/// A `401` on an extension-initiated upload is the app's problem to solve: the
/// background session delivers the completion to the containing app, which
/// refreshes and resubmits.
public struct TokenReader: TokenReading {
    let keychain: any KeychainItemStoring
    let accessGroup: String

    public init(
        keychain: some KeychainItemStoring = SystemKeychain(),
        accessGroup: String = AppGroup.keychainAccessGroup
    ) {
        self.keychain = keychain
        self.accessGroup = accessGroup
    }

    var clientRegistrationItem: KeychainItem {
        TokenKeychainItems.clientRegistration(accessGroup: accessGroup)
    }

    var tokensItem: KeychainItem {
        TokenKeychainItems.tokens(accessGroup: accessGroup)
    }

    public func clientID() throws -> String? {
        guard let data = try keychain.data(for: clientRegistrationItem) else { return nil }
        guard let clientID = String(data: data, encoding: .utf8) else {
            throw KeychainError.malformedItem(account: clientRegistrationItem.account)
        }
        return clientID
    }

    public func tokens() throws -> TokenSet? {
        guard let data = try keychain.data(for: tokensItem) else { return nil }
        do {
            return try JSONDecoder().decode(TokenSet.self, from: data)
        } catch {
            // The decoding error is dropped on purpose: its context can quote
            // the bytes it choked on, and those bytes are the credential.
            throw KeychainError.malformedItem(account: tokensItem.account)
        }
    }

    public func hasUsableAccessToken() throws -> Bool {
        try tokens()?.accessToken.isEmpty == false
    }
}

/// The containing app's read/write view of the shared Keychain.
///
/// This is the only type that writes credentials, and by SPEC 5.4 the app is
/// the only process that ever holds one.
public struct TokenStore: TokenReading, TokenWriting {
    private let reader: TokenReader
    private var keychain: any KeychainItemStoring { reader.keychain }

    public init(
        keychain: some KeychainItemStoring = SystemKeychain(),
        accessGroup: String = AppGroup.keychainAccessGroup
    ) {
        reader = TokenReader(keychain: keychain, accessGroup: accessGroup)
    }

    // MARK: Reading

    public func clientID() throws -> String? { try reader.clientID() }

    public func tokens() throws -> TokenSet? { try reader.tokens() }

    public func hasUsableAccessToken() throws -> Bool { try reader.hasUsableAccessToken() }

    // MARK: Writing

    public func setClientID(_ clientID: String) throws {
        try keychain.set(Data(clientID.utf8), for: reader.clientRegistrationItem)
    }

    public func setTokens(_ tokens: TokenSet) throws {
        try keychain.set(JSONEncoder().encode(tokens), for: reader.tokensItem)
    }

    public func deleteTokens() throws {
        try keychain.removeItem(reader.tokensItem)
    }

    public func deleteAll() throws {
        try deleteTokens()
        try keychain.removeItem(reader.clientRegistrationItem)
    }
}
