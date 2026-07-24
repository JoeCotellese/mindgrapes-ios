// ABOUTME: Covers the token store round trip, absence-versus-failure, and the read-only accessor.
// ABOUTME: Runs against the in-memory Keychain double; the real SecItem calls need a simulator.

import Foundation
import Testing

@testable import MindGrapesKit

private let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)

private func makeTokens(
    access: String = "access-fixture",
    refresh: String = "refresh-fixture",
    secondsRemaining: TimeInterval = 600
) -> TokenSet {
    TokenSet(
        accessToken: access,
        refreshToken: refresh,
        accessTokenExpiresAt: issuedAt.addingTimeInterval(secondsRemaining)
    )
}

private func makeStore() -> (TokenStore, InMemoryKeychain) {
    let keychain = InMemoryKeychain()
    return (TokenStore(keychain: keychain), keychain)
}

// MARK: - Round trip

@Test func tokensRoundTripThroughTheStore() throws {
    let (store, _) = makeStore()
    let tokens = makeTokens()

    try store.setTokens(tokens)
    let read = try #require(try store.tokens())
    #expect(read.accessToken == tokens.accessToken)
    #expect(read.refreshToken == tokens.refreshToken)
    #expect(read.accessTokenExpiresAt == tokens.accessTokenExpiresAt)

    try store.deleteTokens()
    #expect(try store.tokens() == nil)
}

@Test func clientIDRoundTripsThroughTheStore() throws {
    let (store, _) = makeStore()

    try store.setClientID("client-abc123")
    #expect(try store.clientID() == "client-abc123")
}

@Test func rotatingTokensReplacesTheStoredPair() throws {
    // Refresh rotates the pair on every call (SPEC 5.3); a stale copy left
    // behind would be replayed and trip family revocation.
    let (store, keychain) = makeStore()

    try store.setTokens(makeTokens(access: "first", refresh: "first-refresh"))
    try store.setTokens(makeTokens(access: "second", refresh: "second-refresh"))

    let read = try #require(try store.tokens())
    #expect(read.accessToken == "second")
    #expect(read.refreshToken == "second-refresh")
    #expect(keychain.storedItems.count == 1)
}

@Test func clientIDSurvivesTokenDeletion() throws {
    // SPEC 5.3: re-auth reuses the stored client_id; DCR is not repeated.
    let (store, _) = makeStore()
    try store.setClientID("client-abc123")
    try store.setTokens(makeTokens())

    try store.deleteTokens()

    #expect(try store.tokens() == nil)
    #expect(try store.clientID() == "client-abc123")
}

@Test func deletingEverythingAlsoDropsTheRegistration() throws {
    // Disconnecting from a server is the one case where the client_id goes too:
    // it is registered with that server and means nothing to another.
    let (store, keychain) = makeStore()
    try store.setClientID("client-abc123")
    try store.setTokens(makeTokens())

    try store.deleteAll()

    #expect(try store.clientID() == nil)
    #expect(try store.tokens() == nil)
    #expect(keychain.storedItems.isEmpty)
}

@Test func deletingSomethingAbsentIsNotAnError() throws {
    let (store, _) = makeStore()
    try store.deleteTokens()
    try store.deleteAll()
}

// MARK: - Absence versus failure

@Test func missingItemsReadAsNilNotAsAnError() throws {
    let (store, _) = makeStore()

    #expect(try store.tokens() == nil)
    #expect(try store.clientID() == nil)
    #expect(try store.hasUsableAccessToken() == false)
}

@Test func keychainFailuresSurfaceRatherThanReadingAsAbsent() throws {
    // The dangerous silent failure: a Keychain error read as "no token stored"
    // would sign the user out and lose the reason why.
    let (store, keychain) = makeStore()
    keychain.failEverythingWith(.unhandled(status: -34018))

    #expect(throws: KeychainError.unhandled(status: -34018)) { try store.tokens() }
    #expect(throws: KeychainError.unhandled(status: -34018)) { try store.clientID() }
    #expect(throws: KeychainError.unhandled(status: -34018)) { try store.hasUsableAccessToken() }
    #expect(throws: KeychainError.unhandled(status: -34018)) { try store.setTokens(makeTokens()) }
    #expect(throws: KeychainError.unhandled(status: -34018)) { try store.deleteTokens() }
}

@Test func malformedStoredBytesSurfaceAsAnError() throws {
    let (store, keychain) = makeStore()
    keychain.preload(
        Data("not a token blob".utf8),
        for: TokenKeychainItems.tokens(accessGroup: AppGroup.keychainAccessGroup)
    )

    #expect(throws: KeychainError.malformedItem(account: "oauth_tokens")) {
        try store.tokens()
    }
}

// MARK: - Usability

@Test func aStoredTokenIsUsableEvenWhenExpired() throws {
    // SPEC 5.4: extensions send whatever is stored, expired or not. Reporting
    // an expired token as unusable is the shape that pushes an out-of-process
    // refresh, which is exactly what must never happen.
    let (store, _) = makeStore()
    try store.setTokens(makeTokens(secondsRemaining: -3600))

    #expect(try store.hasUsableAccessToken())
}

@Test func anEmptyAccessTokenIsNotUsable() throws {
    let (store, _) = makeStore()
    try store.setTokens(makeTokens(access: ""))

    #expect(try store.hasUsableAccessToken() == false)
}

// MARK: - Keychain placement

@Test func itemsLandInTheSharedAccessGroupUnderDistinctAccounts() throws {
    let (store, keychain) = makeStore()
    try store.setClientID("client-abc123")
    try store.setTokens(makeTokens())

    let items = Set(keychain.storedItems.keys)
    #expect(items.count == 2)
    #expect(items.allSatisfy { $0.accessGroup == AppGroup.keychainAccessGroup })
    #expect(items.allSatisfy { $0.service == "net.cotellese.mindgrapes.oauth" })
    #expect(Set(items.map(\.account)) == ["client_registration", "oauth_tokens"])
}

@Test func accountNamesAreStable() {
    // Renaming an account strands the stored credential silently: the read
    // finds nothing and the user is asked to sign in again for no visible
    // reason.
    let group = AppGroup.keychainAccessGroup
    #expect(TokenKeychainItems.tokens(accessGroup: group).account == "oauth_tokens")
    #expect(
        TokenKeychainItems.clientRegistration(accessGroup: group).account
            == "client_registration"
    )
}

// MARK: - The read-only accessor

@Test func theReaderSeesWhatTheStoreWrote() throws {
    let keychain = InMemoryKeychain()
    let store = TokenStore(keychain: keychain)
    let reader = TokenReader(keychain: keychain)

    try store.setClientID("client-abc123")
    try store.setTokens(makeTokens(access: "shared-access"))

    #expect(try reader.tokens()?.accessToken == "shared-access")
    #expect(try reader.clientID() == "client-abc123")
    #expect(try reader.hasUsableAccessToken())
}

@Test func theReaderExposesNoMutation() {
    // SPEC 5.4's enforcement point. The extension-facing type is not a writer,
    // so no amount of casting reaches a mutation or, more importantly, a path
    // that could refresh out of process and trip family revocation.
    let reader = TokenReader(keychain: InMemoryKeychain())
    #expect((reader as Any) is any TokenWriting == false)
    #expect((reader as Any) is TokenStore == false)
    // Conformance to the read side is a compile-time constraint, so the
    // compiler rejects the file rather than the test failing at runtime.
    func requireReadable<T: TokenReading>(_: T.Type) {}
    requireReadable(TokenReader.self)

    // The app's store is the only writer, and it is a distinct type.
    #expect((TokenStore(keychain: InMemoryKeychain()) as Any) is any TokenWriting)
}

@Test func theReaderCarriesNoWriterToReachThrough() {
    // Belt and braces on the type check above: nothing stored on the reader is
    // itself a writer, so there is no `reader.store.setTokens(…)` back door.
    let reader = TokenReader(keychain: InMemoryKeychain())
    for child in Mirror(reflecting: reader).children {
        #expect((child.value as Any) is any TokenWriting == false)
    }
}

@Test func readerFailuresAlsoSurface() throws {
    let keychain = InMemoryKeychain()
    keychain.failEverythingWith(.unhandled(status: -34018))
    let reader = TokenReader(keychain: keychain)

    #expect(throws: KeychainError.unhandled(status: -34018)) { try reader.tokens() }
    #expect(throws: KeychainError.unhandled(status: -34018)) { try reader.hasUsableAccessToken() }
}

@Test func tokenStoreTypesAreSendable() {
    func requireSendable<T: Sendable>(_: T.Type) {}
    requireSendable(TokenStore.self)
    requireSendable(TokenReader.self)
}
