// ABOUTME: Builds the requests for /healthz, /capture/note, and /capture/image and reads the answers.
// ABOUTME: Owns no session and no token lifecycle; both are handed in, so this stays testable and reusable.

import Foundation

/// The Mind Grapes server contract as the app sees it (SPEC 6).
///
/// Request construction is public and separate from sending because item 6
/// submits the same requests through a background `URLSession` with the body in
/// a spool file, where this type's `async` methods cannot be used.
///
/// The session is injected and never constructed here: a background session is
/// created once per process against a fixed identifier, so a type that made its
/// own could not participate in one.
public struct BrainClient: Sendable {
    public let config: ServerConfig
    private let session: URLSession

    public init(config: ServerConfig, session: URLSession) {
        self.config = config
        self.session = session
    }

    // MARK: - Request construction

    /// SPEC 6.1. Deliberately unauthenticated: onboarding probes a URL the user
    /// typed, and a bearer must not be sent to a host nothing has verified yet.
    public func healthRequest() -> URLRequest {
        var request = URLRequest(url: endpoint("healthz"))
        request.httpMethod = "GET"
        return request
    }

    /// SPEC 6.4. The body comes from `CaptureWireEncoder.noteBody(for:)`.
    public func noteRequest(body: Data, accessToken: String) -> URLRequest {
        var request = authorizedPost(to: "capture/note", accessToken: accessToken)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// SPEC 6.3. The `Content-Type` has to name the boundary the body was framed
    /// with, which is why this takes the whole `MultipartFormBody` rather than
    /// its bytes.
    public func imageRequest(body: MultipartFormBody, accessToken: String) -> URLRequest {
        var request = authorizedPost(to: "capture/image", accessToken: accessToken)
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data
        return request
    }

    // MARK: - Sending

    /// Reachability (SPEC 6.1). Throws rather than returning a `Bool` so a caller
    /// learns *why* a server is unreachable.
    public func checkHealth() async throws {
        let body = try await perform(healthRequest())
        // A 200 alone is not evidence of a Mind Grapes server: captive portals
        // and unrelated sites answer 200 to anything.
        guard String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
            throw BrainClientError.malformedResponse
        }
    }

    public func postNote(body: Data, accessToken: String) async throws -> NoteCaptureResponse {
        try decode(try await perform(noteRequest(body: body, accessToken: accessToken)))
    }

    public func postImage(body: MultipartFormBody, accessToken: String) async throws -> ImageCaptureResponse {
        try decode(try await perform(imageRequest(body: body, accessToken: accessToken)))
    }

    // MARK: - Response shapes

    /// SPEC 6.4's documented minimum.
    public struct NoteCaptureResponse: Sendable, Equatable, Decodable {
        public let experienceID: String

        enum CodingKeys: String, CodingKey {
            case experienceID = "experience_id"
        }
    }

    /// SPEC 6.3's success body.
    ///
    /// Identifiers are `String` rather than `UUID` because the client only ever
    /// stores and echoes them; parsing them would turn a server that changed its
    /// identifier format into a failed capture for no gain.
    public struct ImageCaptureResponse: Sendable, Equatable, Decodable {
        public let experienceID: String
        public let attachmentID: String
        public let objectKey: String
        public let byteLength: Int

        enum CodingKeys: String, CodingKey {
            case experienceID = "experience_id"
            case attachmentID = "attachment_id"
            case objectKey = "object_key"
            case byteLength = "byte_len"
        }
    }

    // MARK: - Plumbing

    /// Appends to the configured base URL rather than replacing its path, so a
    /// server mounted under a subpath by a reverse proxy still resolves. This is
    /// also what makes a trailing slash on the user's input irrelevant.
    private func endpoint(_ path: String) -> URL {
        config.baseURL.appending(path: path)
    }

    private func authorizedPost(to path: String, accessToken: String) -> URLRequest {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Sends and reduces the outcome to either body bytes or a typed error.
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw BrainClientError.transport(error.code)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BrainClientError.malformedResponse
        }

        switch http.statusCode {
        case 200...299: return data
        case 400: throw BrainClientError.badRequest
        case 401: throw BrainClientError.unauthorized
        case 405: throw BrainClientError.methodNotAllowed
        case 413: throw BrainClientError.payloadTooLarge
        case 415: throw BrainClientError.unsupportedMediaType
        case 502: throw BrainClientError.badGateway
        default: throw BrainClientError.unexpectedStatus(http.statusCode)
        }
    }

    /// A body that will not decode is a failure even behind a 200: the capture
    /// cannot be marked succeeded without the identifier the response carries.
    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw BrainClientError.malformedResponse
        }
    }
}
