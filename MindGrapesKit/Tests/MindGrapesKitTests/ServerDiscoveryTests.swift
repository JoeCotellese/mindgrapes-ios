// ABOUTME: Covers URL normalization and the 3-way /healthz reachability probe (item #9, thin).
// ABOUTME: Normalization is pure; the probe is scripted through a dedicated URLProtocol channel.

import Foundation
import Testing

@testable import MindGrapesKit

// MARK: - Normalization (pure)

@Suite("ServerDiscovery normalization")
struct ServerDiscoveryNormalizationTests {
    @Test(
        "raw input normalizes to a base URL",
        arguments: [
            // A bare host defaults to https.
            ("grapes.example.ts.net", "https://grapes.example.ts.net"),
            // Surrounding whitespace is stripped.
            ("  grapes.example.ts.net  ", "https://grapes.example.ts.net"),
            // An explicit http scheme and a port survive.
            ("http://192.168.1.10:8080", "http://192.168.1.10:8080"),
            // A reverse-proxy subpath (and its trailing slash) is preserved.
            ("https://example.com/grapes/", "https://example.com/grapes/"),
            // "host:port" is a host and a port, not a scheme.
            ("example.com:8080", "https://example.com:8080"),
        ] as [(String, String)]
    )
    func normalizes(input: String, expected: String) {
        #expect(ServerDiscovery.normalizedURL(from: input)?.absoluteString == expected)
    }

    @Test func aMixedCaseHTTPSchemeIsAccepted() {
        // Scheme comparison must be case-insensitive; the user may type HTTPS://.
        let url = ServerDiscovery.normalizedURL(from: "HTTPS://Example.com")
        #expect(url?.scheme?.lowercased() == "https")
        #expect(url?.host()?.isEmpty == false)
    }

    @Test(
        "unusable input yields nil",
        arguments: [
            "",                       // nothing
            "   ",                    // whitespace only
            "ftp://example.com",      // a scheme we cannot probe over
            "has space.com",          // an interior space is unparseable
            "https://",               // a scheme with no host
        ]
    )
    func rejects(input: String) {
        #expect(ServerDiscovery.normalizedURL(from: input) == nil)
    }
}
