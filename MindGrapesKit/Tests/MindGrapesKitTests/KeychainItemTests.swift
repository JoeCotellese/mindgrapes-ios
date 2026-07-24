// ABOUTME: Asserts the exact SecItem dictionaries and status mapping the real Keychain uses.
// ABOUTME: Host-testable because building the dictionary needs no entitlement; the call would.

import Foundation
import Security
import Testing

@testable import MindGrapesKit

private let item = KeychainItem(
    service: "net.cotellese.mindgrapes.oauth",
    account: "oauth_tokens",
    accessGroup: AppGroup.keychainAccessGroup
)

private func string(_ dictionary: [String: Any], _ key: CFString) -> String? {
    dictionary[key as String] as? String
}

private func flag(_ dictionary: [String: Any], _ key: CFString) -> Bool? {
    dictionary[key as String] as? Bool
}

// MARK: - Attributes on write

@Test func addAttributesCarryTheSharedAccessGroupAndIdentity() {
    let attributes = item.addAttributes(data: Data([0x01]))

    #expect(string(attributes, kSecClass) == kSecClassGenericPassword as String)
    #expect(string(attributes, kSecAttrService) == "net.cotellese.mindgrapes.oauth")
    #expect(string(attributes, kSecAttrAccount) == "oauth_tokens")
    #expect(string(attributes, kSecAttrAccessGroup) == AppGroup.keychainAccessGroup)
    #expect(attributes[kSecValueData as String] as? Data == Data([0x01]))
}

@Test func storedItemsAreReadableAfterFirstUnlock() {
    // SPEC 5.3: background queue drains read this while the device is locked.
    // `WhenUnlocked` would strand the queue, so the flag is asserted rather
    // than left to a code reading.
    #expect(
        string(item.addAttributes(data: Data()), kSecAttrAccessible)
            == kSecAttrAccessibleAfterFirstUnlock as String
    )
    #expect(
        string(item.updateAttributes(data: Data()), kSecAttrAccessible)
            == kSecAttrAccessibleAfterFirstUnlock as String
    )
}

@Test func storedItemsNeverSyncToICloud() {
    // SPEC 5.3: a refresh token synced to a second device and used from both
    // trips family revocation and signs the user out of everything.
    #expect(flag(item.addAttributes(data: Data()), kSecAttrSynchronizable) == false)
    // Queries pin it too, so a synchronizable item could never be matched even
    // if some other build had written one.
    #expect(flag(item.baseQuery, kSecAttrSynchronizable) == false)
    #expect(flag(item.fetchQuery, kSecAttrSynchronizable) == false)
}

@Test func accessibilityAndAccessGroupAreNotCallerConfigurable() {
    // The only knobs a caller has are service, account, and access group. There
    // is no initializer parameter that could downgrade accessibility or turn
    // syncing on, which is the point: the dangerous options are not options.
    let other = KeychainItem(service: "s", account: "a", accessGroup: "g")
    #expect(
        string(other.addAttributes(data: Data()), kSecAttrAccessible)
            == kSecAttrAccessibleAfterFirstUnlock as String
    )
    #expect(flag(other.addAttributes(data: Data()), kSecAttrSynchronizable) == false)
}

// MARK: - Queries

@Test func fetchQueryAsksForOneItemsData() {
    let query = item.fetchQuery

    #expect(string(query, kSecClass) == kSecClassGenericPassword as String)
    #expect(string(query, kSecAttrService) == "net.cotellese.mindgrapes.oauth")
    #expect(string(query, kSecAttrAccount) == "oauth_tokens")
    #expect(string(query, kSecAttrAccessGroup) == AppGroup.keychainAccessGroup)
    #expect(flag(query, kSecReturnData) == true)
    #expect(string(query, kSecMatchLimit) == kSecMatchLimitOne as String)
}

@Test func baseQueryIdentifiesTheItemWithoutRequestingItsData() {
    // Used for delete and as the update predicate, where returning the secret
    // would be pointless work on a value nothing reads.
    let query = item.baseQuery

    #expect(string(query, kSecClass) == kSecClassGenericPassword as String)
    #expect(query[kSecReturnData as String] == nil)
    #expect(query[kSecValueData as String] == nil)
}

@Test func updateAttributesCarryOnlyTheChangedValues() {
    // SecItemUpdate takes the fields to change, not the item's identity; the
    // identity lives in the predicate.
    let attributes = item.updateAttributes(data: Data([0x02]))

    #expect(attributes[kSecValueData as String] as? Data == Data([0x02]))
    #expect(attributes[kSecClass as String] == nil)
    #expect(attributes[kSecAttrService as String] == nil)
    #expect(attributes[kSecAttrAccount as String] == nil)
}

// MARK: - Status interpretation

@Test func missingItemsAreDistinguishedFromFailures() throws {
    // The critical distinction: "no token stored" is a normal state, but a real
    // Keychain failure read as absent would silently sign the user out.
    #expect(try KeychainOutcome(status: errSecSuccess) == .found)
    #expect(try KeychainOutcome(status: errSecItemNotFound) == .notFound)
}

@Test func unexpectedStatusesSurfaceAsErrors() {
    // -34018 is `errSecMissingEntitlement`, exactly what a mis-provisioned
    // build or a plain host test binary gets back.
    #expect(throws: KeychainError.unhandled(status: -34018)) {
        try KeychainOutcome(status: -34018)
    }
    #expect(throws: KeychainError.unhandled(status: errSecInteractionNotAllowed)) {
        try KeychainOutcome(status: errSecInteractionNotAllowed)
    }
}

@Test func keychainTypesAreSendable() {
    func requireSendable<T: Sendable>(_: T.Type) {}
    requireSendable(KeychainItem.self)
    requireSendable(KeychainError.self)
    requireSendable(SystemKeychain.self)
}
