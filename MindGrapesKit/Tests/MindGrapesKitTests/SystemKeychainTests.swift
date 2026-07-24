// ABOUTME: Exercises the real SecItem-backed Keychain, for a host that has the entitlement.
// ABOUTME: Opt-in: no SPM test bundle carries `keychain-access-groups`, so SecItem returns -34018.

#if os(iOS)

import Foundation
import Testing

@testable import MindGrapesKit

/// Whether this process can be expected to reach a Keychain access group.
///
/// Measured, not assumed. `swift test` on macOS fails these with
/// `errSecMissingEntitlement` (-34018), and so does `xcodebuild test` against
/// an iOS simulator: an SPM test bundle runs in the generic `xctest` runner,
/// which carries no `keychain-access-groups` entitlement either. Verifying the
/// real calls therefore needs a test target hosted by the signed app, which is
/// a `project.yml` change and a separate piece of work.
///
/// Until then these run only when something that *does* hold the entitlement
/// asks for them:
///
///     MINDGRAPES_KEYCHAIN_TESTS=1 xcodebuild test …
private let keychainEntitlementAvailable =
    ProcessInfo.processInfo.environment["MINDGRAPES_KEYCHAIN_TESTS"] == "1"

/// The part of the store the host suite cannot reach: the `SecItem` calls
/// themselves. Everything above the seam is covered in `TokenStoreTests` and
/// `KeychainItemTests`, which run everywhere.
///
/// Serialized: they share one live Keychain, so a parallel run would have two
/// tests writing and deleting the same item.
@Suite(.serialized, .enabled(if: keychainEntitlementAvailable))
struct SystemKeychainTests {
    /// A service of its own, so a failed run cannot disturb a real install's
    /// credentials on the same device.
    private static let item = KeychainItem(
        service: "net.cotellese.mindgrapes.oauth.tests",
        account: "round_trip",
        accessGroup: AppGroup.keychainAccessGroup
    )

    private let keychain = SystemKeychain()

    private func clean() throws {
        try keychain.removeItem(Self.item)
    }

    @Test func dataRoundTripsThroughTheRealKeychain() throws {
        try clean()
        defer { try? clean() }

        try keychain.set(Data("first".utf8), for: Self.item)
        #expect(try keychain.data(for: Self.item) == Data("first".utf8))

        // Second write is the rotation path: SecItemAdd reports a duplicate and
        // the value is updated in place.
        try keychain.set(Data("second".utf8), for: Self.item)
        #expect(try keychain.data(for: Self.item) == Data("second".utf8))

        try keychain.removeItem(Self.item)
        #expect(try keychain.data(for: Self.item) == nil)
    }

    @Test func removingSomethingAbsentSucceeds() throws {
        try clean()
        try keychain.removeItem(Self.item)
    }

    @Test func storedItemIsAccessibleAfterFirstUnlockAndUnsynced() throws {
        try clean()
        defer { try? clean() }
        try keychain.set(Data("value".utf8), for: Self.item)

        var query = Self.item.baseQuery
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])

        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlock as String
        )
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool != true)
    }

    @Test func theTokenStoreRoundTripsAgainstTheRealKeychain() throws {
        let store = TokenStore()
        defer { try? store.deleteAll() }
        try store.deleteAll()

        try store.setClientID("client-abc123")
        try store.setTokens(
            TokenSet(
                accessToken: "access-fixture",
                refreshToken: "refresh-fixture",
                accessTokenExpiresAt: Date(timeIntervalSince1970: 1_700_000_600)
            )
        )

        #expect(try store.clientID() == "client-abc123")
        #expect(try store.tokens()?.refreshToken == "refresh-fixture")
        #expect(try store.hasUsableAccessToken())

        // The extension's view reads the same items with no writer in reach.
        #expect(try TokenReader().tokens()?.accessToken == "access-fixture")

        try store.deleteTokens()
        #expect(try store.tokens() == nil)
        #expect(try store.clientID() == "client-abc123")
    }
}

#endif
