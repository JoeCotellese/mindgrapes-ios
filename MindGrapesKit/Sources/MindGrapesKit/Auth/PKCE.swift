// ABOUTME: PKCE (RFC 7636) code verifier and S256 challenge for the OAuth authorization-code flow.
// ABOUTME: Pure and deterministic given a verifier, so the challenge is testable against the RFC vector.

import CryptoKit
import Foundation

/// A PKCE verifier/challenge pair (RFC 7636), `S256` only.
///
/// The server enforces `S256` (`oauth/grants.py:25-32`, SPEC 5.1), so `plain`
/// is not offered. The challenge derivation is pure — a fixed verifier always
/// yields the same challenge — which is what lets the tests pin it to the RFC
/// 7636 Appendix B test vector instead of trusting the implementation to
/// describe itself.
public struct PKCE: Sendable, Equatable {
    /// The high-entropy secret, kept by the client and sent only at code
    /// exchange. 43–128 characters from the unreserved set (RFC 7636 §4.1).
    public let verifier: String

    /// The transform sent in the authorization request. Always `"S256"`.
    public let method = "S256"

    public init(verifier: String) {
        self.verifier = verifier
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))`, no padding (RFC 7636 §4.2).
    public var challenge: String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Self.base64URLNoPadding(Data(digest))
    }

    /// A fresh verifier from 32 random bytes, base64url-encoded to 43 characters.
    /// The RNG is injected so tests are reproducible; production uses the system
    /// source.
    public static func random(using rng: inout some RandomNumberGenerator) -> PKCE {
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for _ in 0..<32 { bytes.append(rng.next()) }
        return PKCE(verifier: base64URLNoPadding(Data(bytes)))
    }

    public static func random() -> PKCE {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    private static func base64URLNoPadding(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
