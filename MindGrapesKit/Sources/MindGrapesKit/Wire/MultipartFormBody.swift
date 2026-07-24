// ABOUTME: Assembles multipart/form-data bytes and the boundary that frames them.
// ABOUTME: Carries no knowledge of captures; CaptureWireEncoder decides which fields go in.

import Foundation

/// A finished `multipart/form-data` body and the boundary it was framed with.
///
/// The caller sets the header, because item 4 owns `URLRequest` construction and
/// this type owns bytes.
public struct MultipartFormBody: Sendable, Equatable {
    public let boundary: String
    public let data: Data

    /// The exact `Content-Type` this body must be sent with.
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    init(boundary: String, data: Data) {
        self.boundary = boundary
        self.data = data
    }

    /// A boundary with enough entropy that a payload collision is a curiosity
    /// rather than a risk. The prefix is there to make a captured request
    /// obviously ours; the UUID does the work.
    ///
    /// Every character is in RFC 2046's boundary set, and the whole thing is 47
    /// characters against a limit of 70.
    public static func makeBoundary() -> String { "MindGrapes-\(UUID().uuidString)" }

    /// RFC 2046 allows more than this. Narrowing to letters, digits, and the
    /// hyphen keeps a boundary from needing quoting in the header, and the
    /// generator never reaches for anything else.
    private static let allowedCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"
    )

    static func isWellFormed(_ boundary: String) -> Bool {
        (1...70).contains(boundary.count) && boundary.allSatisfy(allowedCharacters.contains)
    }
}

/// Collects parts in call order and renders them once a boundary is settled.
struct MultipartFormBuilder {
    private enum Part {
        case field(name: String, value: String)
        case file(name: String, filename: String, contentType: String, data: Data)
    }

    private var parts: [Part] = []

    mutating func addField(_ name: String, _ value: String) {
        parts.append(.field(name: name, value: value))
    }

    mutating func addFile(_ name: String, filename: String, contentType: String, data: Data) {
        parts.append(
            .file(name: name, filename: Self.escapedFilename(filename), contentType: contentType, data: data)
        )
    }

    /// Renders the body.
    ///
    /// Pass `nil` to have a boundary generated, which retries on the vanishingly
    /// unlikely collision. A supplied boundary is validated and then refused if
    /// the payload contains it, because silently substituting a different one
    /// would break a caller that already wrote the header.
    func build(boundary requested: String?) throws -> MultipartFormBody {
        let boundary: String
        if let requested {
            guard MultipartFormBody.isWellFormed(requested) else {
                throw CaptureEncodingError.invalidBoundary(requested)
            }
            guard !payloadContains(requested) else {
                throw CaptureEncodingError.boundaryCollision(requested)
            }
            boundary = requested
        } else {
            var candidate = MultipartFormBody.makeBoundary()
            while payloadContains(candidate) {
                candidate = MultipartFormBody.makeBoundary()
            }
            boundary = candidate
        }

        var data = Data()
        for part in parts {
            data.append(Data("--\(boundary)\r\n".utf8))
            switch part {
            case let .field(name, value):
                data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
                data.append(Data(value.utf8))
            case let .file(name, filename, contentType, payload):
                data.append(
                    Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8)
                )
                data.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
                data.append(payload)
            }
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return MultipartFormBody(boundary: boundary, data: data)
    }

    /// Whether the boundary token appears anywhere a reader would mistake it for
    /// a delimiter. Field names are compile-time literals, so only caller-supplied
    /// content is worth scanning.
    private func payloadContains(_ boundary: String) -> Bool {
        let token = Data(boundary.utf8)
        return parts.contains { part in
            switch part {
            case let .field(_, value):
                return Data(value.utf8).range(of: token) != nil
            case let .file(_, filename, _, data):
                return data.range(of: token) != nil || Data(filename.utf8).range(of: token) != nil
            }
        }
    }

    /// Percent-encodes the three characters that would otherwise let a filename
    /// close the quoted parameter or forge a header, matching what browsers do
    /// (RFC 7578 §5.1 leaves the escaping to the sender).
    private static func escapedFilename(_ filename: String) -> String {
        filename
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}
