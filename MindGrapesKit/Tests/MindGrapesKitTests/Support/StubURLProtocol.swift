// ABOUTME: A URLProtocol that answers every request from a test-supplied handler.
// ABOUTME: Lets the client suite script each documented status without a server.

import Foundation

/// Intercepts every request on a session configured with it and answers from
/// whatever the current test installed.
///
/// The handler storage is process-global because `URLProtocol` is instantiated
/// by `URLSession`, which gives a test no seam to inject through. To let
/// independent suites use the stub without clobbering each other under parallel
/// execution, storage is keyed per **subclass**: each concrete stub type below
/// is its own channel. Within one channel, suites must still be `.serialized`,
/// since two of its tests scripting different answers at once would collide.
class StubURLProtocolBase: URLProtocol {
    /// Either an HTTP answer or a transport failure, which are the two shapes
    /// SPEC 6.3's error table distinguishes.
    typealias Handler = @Sendable (URLRequest) -> Result<(HTTPURLResponse, Data), URLError>

    nonisolated(unsafe) private static var handlers: [ObjectIdentifier: Handler] = [:]
    private static let lock = NSLock()

    /// A session that routes through this protocol and caches nothing, so one
    /// test's 200 cannot answer the next test's request.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [self]
        return URLSession(configuration: configuration)
    }

    static func install(_ handler: @escaping Handler) {
        let channel = ObjectIdentifier(self)
        lock.withLock { Self.handlers[channel] = handler }
    }

    /// Answers every request with the given status and body.
    static func install(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
        install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return .success((response, body))
        }
    }

    static func install(status: Int, text: String) {
        install(status: status, body: Data(text.utf8))
    }

    /// Fails every request the way a device with no route would.
    static func installTransportFailure(_ code: URLError.Code) {
        install { _ in .failure(URLError(code)) }
    }

    static func reset() {
        let channel = ObjectIdentifier(self)
        lock.withLock { Self.handlers[channel] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let channel = ObjectIdentifier(type(of: self))
        guard let handler = Self.lock.withLock({ Self.handlers[channel] }) else {
            // A test that forgot to install one should fail loudly rather than
            // hang or silently succeed.
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        switch handler(request) {
        case let .success((response, data)):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// The default channel. Used by `BrainClientTests`.
final class StubURLProtocol: StubURLProtocolBase {}

/// A separate channel for `AuthManagerTests`, so it can script the OAuth token
/// endpoint without racing the `BrainClient` suite under parallel `make test`.
final class AuthStubURLProtocol: StubURLProtocolBase {}

/// A separate channel for `ServerDiscoveryTests`, so its `/healthz` probe cases
/// do not race the `BrainClient` suite scripting the same endpoint.
final class DiscoveryStubURLProtocol: StubURLProtocolBase {}
