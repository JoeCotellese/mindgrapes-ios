// ABOUTME: Covers token expiry evaluation against an injected instant and secret redaction.
// ABOUTME: Expiry is pure so item 8 can drive the refresh decision from a fake clock.

import Foundation
import Testing

@testable import MindGrapesKit

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func makeTokens(secondsRemaining: TimeInterval) -> TokenSet {
    TokenSet(
        accessToken: "access-fixture",
        refreshToken: "refresh-fixture",
        accessTokenExpiresAt: now.addingTimeInterval(secondsRemaining)
    )
}

@Test func accessTokenIsExpiredOnlyOnceTheExpiryInstantHasPassed() {
    #expect(makeTokens(secondsRemaining: 1).isAccessTokenExpired(asOf: now) == false)
    // The boundary counts as expired: a token whose `exp` equals now is already
    // rejected by the server clock.
    #expect(makeTokens(secondsRemaining: 0).isAccessTokenExpired(asOf: now))
    #expect(makeTokens(secondsRemaining: -1).isAccessTokenExpired(asOf: now))
}

@Test func refreshIsNeededUnderSixtySecondsRemaining() {
    // SPEC 5.3: refresh proactively when less than 60 seconds remain.
    #expect(makeTokens(secondsRemaining: 120).needsRefresh(asOf: now) == false)
    #expect(makeTokens(secondsRemaining: 60).needsRefresh(asOf: now) == false)
    #expect(makeTokens(secondsRemaining: 59.5).needsRefresh(asOf: now))
    #expect(makeTokens(secondsRemaining: 0).needsRefresh(asOf: now))
    #expect(makeTokens(secondsRemaining: -600).needsRefresh(asOf: now))
}

@Test func refreshLeadTimeIsSixtySeconds() {
    #expect(TokenSet.refreshLeadTime == 60)
}

@Test func refreshLeadTimeIsOverridableForTests() {
    let tokens = makeTokens(secondsRemaining: 90)
    #expect(tokens.needsRefresh(asOf: now, leadTime: 120))
    #expect(tokens.needsRefresh(asOf: now, leadTime: 30) == false)
}

@Test func tokenSetRoundTripsThroughItsStoredForm() throws {
    let tokens = makeTokens(secondsRemaining: 600)
    let data = try JSONEncoder().encode(tokens)
    let decoded = try JSONDecoder().decode(TokenSet.self, from: data)

    #expect(decoded.accessToken == tokens.accessToken)
    #expect(decoded.refreshToken == tokens.refreshToken)
    #expect(decoded.accessTokenExpiresAt == tokens.accessTokenExpiresAt)
}

@Test func tokenSetCodingKeysAreStable() throws {
    // These names live in the Keychain across app updates; renaming a property
    // must not strand a stored token pair and sign the user out.
    let data = try JSONEncoder().encode(makeTokens(secondsRemaining: 600))
    let object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(Set(object.keys) == ["access_token", "refresh_token", "access_token_expires_at"])
}

@Test func tokenSetDescriptionsRedactSecrets() {
    let tokens = makeTokens(secondsRemaining: 600)

    // Failure output and any log line that interpolates a `TokenSet` must not
    // carry the credential itself.
    for rendering in [String(describing: tokens), String(reflecting: tokens)] {
        #expect(rendering.contains("access-fixture") == false)
        #expect(rendering.contains("refresh-fixture") == false)
    }

    let children = Mirror(reflecting: tokens).children.map { String(describing: $0.value) }
    #expect(children.contains("access-fixture") == false)
    #expect(children.contains("refresh-fixture") == false)
}

@Test func tokenSetIsSendable() {
    func requireSendable<T: Sendable>(_: T.Type) {}
    requireSendable(TokenSet.self)
}
