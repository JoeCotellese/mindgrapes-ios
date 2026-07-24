// ABOUTME: An in-memory KeychainItemStoring double for host tests, with injectable failures.
// ABOUTME: The host has no Keychain access group entitlement, so real SecItem calls cannot run.

import Foundation

@testable import MindGrapesKit

/// A Keychain stand-in that keeps items in a dictionary.
///
/// `@unchecked Sendable` with a lock: the protocol is `Sendable` and the
/// mutable state is small enough to guard directly.
final class InMemoryKeychain: KeychainItemStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [KeychainItem: Data] = [:]
    private var failure: KeychainError?

    init() {}

    // MARK: Test control

    /// Makes every subsequent operation throw, standing in for a Keychain that
    /// is present but refusing (locked, entitlement missing, hardware fault).
    func failEverythingWith(_ error: KeychainError?) {
        lock.withLock { failure = error }
    }

    /// Puts bytes in place without going through the store, so a corrupted or
    /// foreign item can be exercised.
    func preload(_ data: Data, for item: KeychainItem) {
        lock.withLock { items[item] = data }
    }

    var storedItems: [KeychainItem: Data] {
        lock.withLock { items }
    }

    // MARK: KeychainItemStoring

    func data(for item: KeychainItem) throws -> Data? {
        try lock.withLock {
            if let failure { throw failure }
            return items[item]
        }
    }

    func set(_ data: Data, for item: KeychainItem) throws {
        try lock.withLock {
            if let failure { throw failure }
            items[item] = data
        }
    }

    func removeItem(_ item: KeychainItem) throws {
        try lock.withLock {
            if let failure { throw failure }
            items[item] = nil
        }
    }
}
