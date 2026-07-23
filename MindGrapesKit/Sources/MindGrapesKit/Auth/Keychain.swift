// ABOUTME: The Keychain seam: one item description, its SecItem dictionaries, and the real store.
// ABOUTME: Security-framework calls sit behind a protocol so the logic above stays host-testable.

import Foundation
import Security

/// One generic-password item in the shared access group.
///
/// Accessibility and syncing are deliberately *not* initializer parameters.
/// Both have exactly one correct value here (SPEC 5.3) and a wrong one is
/// silent: `WhenUnlocked` strands the background queue, and syncing trips
/// refresh-family revocation. Leaving them out of the API means no caller can
/// pick the wrong one.
public struct KeychainItem: Sendable, Hashable {
    public let service: String
    public let account: String
    public let accessGroup: String

    public init(service: String, account: String, accessGroup: String) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    /// Identifies the item without asking for its bytes. Used as the delete
    /// query and as the update predicate.
    var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// `baseQuery` plus a request for the stored bytes of a single match.
    var fetchQuery: [String: Any] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    /// The full attribute set for `SecItemAdd`.
    func addAttributes(data: Data) -> [String: Any] {
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return attributes
    }

    /// The changed fields for `SecItemUpdate`. Identity stays in the predicate.
    func updateAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }
}

public enum KeychainError: Error, Sendable, Equatable {
    /// A `SecItem` status that is neither success nor "not found". Surfaced
    /// rather than swallowed: reading a real failure as "no token stored" would
    /// sign the user out with no explanation.
    case unhandled(status: OSStatus)

    /// The stored bytes are not the shape this app wrote. The account name is
    /// included; the value never is.
    case malformedItem(account: String)
}

/// What a `SecItem` call meant, once the "normal absence" case is separated
/// from real failure.
enum KeychainOutcome: Sendable, Equatable {
    case found
    case notFound

    /// The one place a raw `OSStatus` is interpreted, so the rule is asserted
    /// on the host even though the calls themselves cannot run there.
    init(status: OSStatus) throws {
        switch status {
        case errSecSuccess: self = .found
        case errSecItemNotFound: self = .notFound
        default: throw KeychainError.unhandled(status: status)
        }
    }
}

/// Reads and writes bytes for a ``KeychainItem``.
///
/// A seam, for the same reason `AppGroupContainerLocating` is one: `swift test`
/// runs on the host, where a test binary has no Keychain access group
/// entitlement and every real call fails with `errSecMissingEntitlement`
/// (-34018). The store's logic is tested against an in-memory double; the
/// implementation below is kept thin enough to read as correct and is verified
/// on a simulator.
public protocol KeychainItemStoring: Sendable {
    /// The stored bytes, or `nil` when nothing is stored. Throws on any other
    /// failure.
    func data(for item: KeychainItem) throws -> Data?

    /// Stores `data`, replacing whatever was there.
    func set(_ data: Data, for item: KeychainItem) throws

    /// Removes the item. Removing something absent is not an error.
    func removeItem(_ item: KeychainItem) throws
}

/// The real store, backed by the Security framework.
public struct SystemKeychain: KeychainItemStoring {
    public init() {}

    public func data(for item: KeychainItem) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item.fetchQuery as CFDictionary, &result)
        guard try KeychainOutcome(status: status) == .found else { return nil }
        guard let data = result as? Data else {
            throw KeychainError.malformedItem(account: item.account)
        }
        return data
    }

    public func set(_ data: Data, for item: KeychainItem) throws {
        let status = SecItemAdd(item.addAttributes(data: data) as CFDictionary, nil)
        guard status == errSecDuplicateItem else {
            _ = try KeychainOutcome(status: status)
            return
        }
        // Something is already stored, so this is a rotation: update in place
        // rather than delete-then-add, which would leave a window in which a
        // concurrently draining extension finds no credential at all.
        _ = try KeychainOutcome(
            status: SecItemUpdate(
                item.baseQuery as CFDictionary,
                item.updateAttributes(data: data) as CFDictionary
            )
        )
    }

    public func removeItem(_ item: KeychainItem) throws {
        // `.notFound` is success here: the caller wanted it gone.
        _ = try KeychainOutcome(status: SecItemDelete(item.baseQuery as CFDictionary))
    }
}
