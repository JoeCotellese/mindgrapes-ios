// ABOUTME: Covers request construction and the status-to-error mapping in SPEC 6.
// ABOUTME: Every documented status is scripted through a URLProtocol stub, no server involved.

import Foundation
import Testing

@testable import MindGrapesKit

private let token = "test-access-token"

private func client(base: String) -> BrainClient {
    BrainClient(
        config: ServerConfig(baseURL: URL(string: base)!),
        session: StubURLProtocol.makeSession()
    )
}

private func multipart(_ text: String) throws -> MultipartFormBody {
    var builder = MultipartFormBuilder()
    builder.addField("description", text)
    return try builder.build(boundary: "MindGrapes-Fixed-Boundary")
}

// MARK: - Request construction

@Suite("BrainClient request construction")
struct BrainClientRequestTests {
    @Test func healthRequestTargetsTheProbeEndpointWithoutAuth() {
        let request = client(base: "https://grapes.example.ts.net").healthRequest()

        #expect(request.url?.absoluteString == "https://grapes.example.ts.net/healthz")
        #expect(request.httpMethod == "GET")
        // SPEC 6.1: no auth. Sending a bearer here would leak it to a URL the
        // user typed during onboarding, before anything has verified the host.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func noteRequestCarriesJSONAndTheBearer() throws {
        let body = Data(#"{"content":"hi"}"#.utf8)
        let request = client(base: "https://grapes.example.ts.net").noteRequest(body: body, accessToken: token)

        #expect(request.url?.absoluteString == "https://grapes.example.ts.net/capture/note")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(request.httpBody == body)
    }

    @Test func imageRequestDeclaresTheBoundaryTheBodyWasFramedWith() throws {
        let body = try multipart("a note about a receipt")
        let request = client(base: "https://grapes.example.ts.net").imageRequest(body: body, accessToken: token)

        #expect(request.url?.absoluteString == "https://grapes.example.ts.net/capture/image")
        #expect(request.httpMethod == "POST")
        // A mismatch here is unparseable at the server and produces a 400 that
        // reads like a field problem, so it is worth pinning.
        #expect(request.value(forHTTPHeaderField: "Content-Type") == body.contentType)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(request.httpBody == body.data)
    }

    @Test func aTrailingSlashOnTheBaseURLChangesNothing() throws {
        let bare = client(base: "https://grapes.example.ts.net")
        let slashed = client(base: "https://grapes.example.ts.net/")
        let body = try multipart("x")

        #expect(bare.healthRequest().url == slashed.healthRequest().url)
        #expect(
            bare.noteRequest(body: Data(), accessToken: token).url
                == slashed.noteRequest(body: Data(), accessToken: token).url
        )
        #expect(
            bare.imageRequest(body: body, accessToken: token).url
                == slashed.imageRequest(body: body, accessToken: token).url
        )
    }

    @Test func aBaseURLWithItsOwnPathKeepsThatPath() {
        // A reverse proxy that mounts the server under a subpath is a supported
        // deployment, so the endpoint has to append rather than replace.
        let request = client(base: "https://example.com/grapes/").healthRequest()

        #expect(request.url?.absoluteString == "https://example.com/grapes/healthz")
    }
}

// MARK: - Response interpretation

/// Serialized because `StubURLProtocol` scripts answers through process-global
/// state.
@Suite("BrainClient response interpretation", .serialized)
struct BrainClientResponseTests {
    private let subject = client(base: "https://grapes.example.ts.net")

    private func noteFailure() async -> BrainClientError? {
        await #expect(throws: BrainClientError.self) {
            try await subject.postNote(body: Data(), accessToken: token)
        }
    }

    // MARK: Success

    @Test func healthAcceptsThePlainTextOK() async throws {
        StubURLProtocol.install(status: 200, text: "ok")
        defer { StubURLProtocol.reset() }

        try await subject.checkHealth()
    }

    @Test func healthRejectsA200FromSomethingThatIsNotAMindGrapesServer() async throws {
        // Onboarding probes a URL the user typed. A captive portal or an
        // unrelated site answering 200 must not read as reachable.
        StubURLProtocol.install(status: 200, text: "<!DOCTYPE html><title>router</title>")
        defer { StubURLProtocol.reset() }

        let error = await #expect(throws: BrainClientError.self) {
            try await subject.checkHealth()
        }
        #expect(error == .malformedResponse)
    }

    @Test func noteSuccessDecodesTheExperienceIdentifier() async throws {
        StubURLProtocol.install(status: 200, text: #"{"experience_id":"6E2F-…"}"#)
        defer { StubURLProtocol.reset() }

        let result = try await subject.postNote(body: Data(), accessToken: token)

        #expect(result.experienceID == "6E2F-…")
    }

    @Test func imageSuccessDecodesEveryDocumentedField() async throws {
        let payload = """
            {"experience_id":"exp-1","attachment_id":"att-1",\
            "object_key":"household/abc.webp","byte_len":43210}
            """
        StubURLProtocol.install(status: 200, text: payload)
        defer { StubURLProtocol.reset() }

        let result = try await subject.postImage(body: try multipart("x"), accessToken: token)

        #expect(result.experienceID == "exp-1")
        #expect(result.attachmentID == "att-1")
        #expect(result.objectKey == "household/abc.webp")
        #expect(result.byteLength == 43210)
    }

    @Test func aSuccessBodyThatWillNotDecodeIsNotASuccess() async throws {
        StubURLProtocol.install(status: 200, text: "not json")
        defer { StubURLProtocol.reset() }

        let error = await noteFailure()

        #expect(error == .malformedResponse)
        #expect(error?.retryDisposition == .terminal)
    }

    // MARK: Documented statuses

    @Test(
        "each documented status maps to its typed error and retry class",
        arguments: [
            (400, BrainClientError.badRequest, RetryDisposition.terminal),
            (401, .unauthorized, .authRequired),
            (405, .methodNotAllowed, .terminal),
            (413, .payloadTooLarge, .terminal),
            (415, .unsupportedMediaType, .terminal),
            (502, .badGateway, .retry),
        ]
    )
    func statusMapping(status: Int, expected: BrainClientError, disposition: RetryDisposition) async throws {
        StubURLProtocol.install(status: status)
        defer { StubURLProtocol.reset() }

        let error = await noteFailure()

        #expect(error == expected)
        #expect(error?.retryDisposition == disposition)
    }

    @Test func anUndocumentedServerErrorIsWorthRetrying() async throws {
        // Nothing says a 503 from a proxy in front of the server wrote anything,
        // and treating it as terminal would discard a capture over a restart.
        StubURLProtocol.install(status: 503)
        defer { StubURLProtocol.reset() }

        let error = await noteFailure()

        #expect(error == .unexpectedStatus(503))
        #expect(error?.retryDisposition == .retry)
    }

    @Test func anUndocumentedClientErrorIsTerminal() async throws {
        StubURLProtocol.install(status: 418)
        defer { StubURLProtocol.reset() }

        let error = await noteFailure()

        #expect(error == .unexpectedStatus(418))
        #expect(error?.retryDisposition == .terminal)
    }

    @Test func aTransportFailureIsWorthRetrying() async throws {
        StubURLProtocol.installTransportFailure(.notConnectedToInternet)
        defer { StubURLProtocol.reset() }

        let error = await noteFailure()

        #expect(error == .transport(.notConnectedToInternet))
        #expect(error?.retryDisposition == .retry)
    }

    @Test func theImageDoorMapsStatusesTheSameWay() async throws {
        // Both doors share an error vocabulary (SPEC 6.4), so a divergence here
        // would be a bug rather than a design.
        StubURLProtocol.install(status: 415)
        defer { StubURLProtocol.reset() }

        let error = await #expect(throws: BrainClientError.self) {
            try await subject.postImage(body: try multipart("x"), accessToken: token)
        }

        #expect(error == .unsupportedMediaType)
    }

    @Test func healthMapsStatusesTheSameWay() async throws {
        StubURLProtocol.install(status: 502)
        defer { StubURLProtocol.reset() }

        let error = await #expect(throws: BrainClientError.self) {
            try await subject.checkHealth()
        }

        #expect(error == .badGateway)
    }
}
