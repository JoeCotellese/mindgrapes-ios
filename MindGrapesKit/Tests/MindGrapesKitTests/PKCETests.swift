// ABOUTME: Pins PKCE S256 derivation to the RFC 7636 Appendix B test vector.
// ABOUTME: Also checks verifier charset and length so a random verifier is always spec-legal.

import Foundation
import Testing

@testable import MindGrapesKit

struct PKCETests {
    /// RFC 7636 Appendix B: the canonical verifier and its S256 challenge. If the
    /// hashing or base64url encoding drifts, this is the assertion that fails.
    @Test func challengeMatchesTheRFC7636TestVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(pkce.method == "S256")
    }

    @Test func challengeIsBase64URLWithoutPaddingOrUnsafeCharacters() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let challenge = pkce.challenge
        #expect(!challenge.contains("="))
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
    }

    @Test func randomVerifierIsSpecLegal() {
        // RFC 7636 §4.1: 43–128 chars from the unreserved set. 32 random bytes
        // base64url-encode to exactly 43 characters.
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SeededRandomNumberGenerator(seed: 99)
        for _ in 0..<200 {
            let verifier = PKCE.random(using: &generator).verifier
            #expect(verifier.count >= 43)
            #expect(verifier.count <= 128)
            #expect(verifier.allSatisfy { unreserved.contains($0) })
        }
    }

    @Test func distinctRandomVerifiersDiffer() {
        var generator = SeededRandomNumberGenerator(seed: 1)
        let first = PKCE.random(using: &generator).verifier
        let second = PKCE.random(using: &generator).verifier
        #expect(first != second)
    }
}
