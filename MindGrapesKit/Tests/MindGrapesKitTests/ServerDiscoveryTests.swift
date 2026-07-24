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

// MARK: - Reachability probe (scripted)

/// Serialized because `DiscoveryStubURLProtocol` scripts answers through
/// process-global state, like the other stub-backed suites.
@Suite("ServerDiscovery reachability", .serialized)
struct ServerDiscoveryProbeTests {
    private let subject = BrainClient(
        config: ServerConfig(baseURL: URL(string: "https://grapes.example.ts.net")!),
        session: DiscoveryStubURLProtocol.makeSession()
    )

    @Test func aMindGrapesServerAnsweringOKIsReachable() async {
        DiscoveryStubURLProtocol.install(status: 200, text: "ok")
        defer { DiscoveryStubURLProtocol.reset() }

        #expect(await subject.probeReachability() == .reachable)
    }

    @Test func aCaptivePortalAnsweringA200IsTheWrongHost() async {
        // The probe reached a live server, but it is not Mind Grapes: the URL is
        // the thing to fix, not the connection.
        DiscoveryStubURLProtocol.install(status: 200, text: "<!DOCTYPE html><title>router</title>")
        defer { DiscoveryStubURLProtocol.reset() }

        #expect(await subject.probeReachability() == .wrongHost)
    }

    @Test func a404IsTheWrongHost() async {
        // Something answered HTTP but has no /healthz. Not a Mind Grapes server.
        DiscoveryStubURLProtocol.install(status: 404)
        defer { DiscoveryStubURLProtocol.reset() }

        #expect(await subject.probeReachability() == .wrongHost)
    }

    @Test func aHealthzDemandingAuthIsTheWrongHost() async {
        // /healthz is unauthenticated by contract (SPEC 6.1). A host that
        // answers 401 here is not Mind Grapes, so the URL is the suspect. This
        // pins the authRequired disposition, the one the ternary folds into
        // wrongHost without saying so.
        DiscoveryStubURLProtocol.install(status: 401)
        defer { DiscoveryStubURLProtocol.reset() }

        #expect(await subject.probeReachability() == .wrongHost)
    }

    @Test(
        "a server-side hiccup reads as unreachable, not wrong host",
        arguments: [502, 503]
    )
    func aServerErrorIsUnreachable(status: Int) async {
        // DNS resolved and something answered, but a 5xx says nothing useful
        // about the URL, so telling the user to fix it would be wrong.
        DiscoveryStubURLProtocol.install(status: status)
        defer { DiscoveryStubURLProtocol.reset() }

        #expect(await subject.probeReachability() == .unreachable)
    }

    @Test func aTransportFailureIsUnreachable() async {
        DiscoveryStubURLProtocol.installTransportFailure(.notConnectedToInternet)
        defer { DiscoveryStubURLProtocol.reset() }

        #expect(await subject.probeReachability() == .unreachable)
    }
}
