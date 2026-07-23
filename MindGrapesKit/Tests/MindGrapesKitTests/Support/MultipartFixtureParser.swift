// ABOUTME: A test-only multipart/form-data reader used to round-trip encoded bodies.
// ABOUTME: Deliberately independent of the encoder so a shared bug cannot cancel itself out.

import Foundation

@testable import MindGrapesKit

/// One decoded part of a multipart body.
struct MultipartPart: Equatable {
    let name: String
    let filename: String?
    let contentType: String?
    let body: Data

    /// The part's payload read as UTF-8, which is how every field the client
    /// sends is encoded.
    var text: String { String(decoding: body, as: UTF8.self) }
}

enum MultipartParseError: Error, Equatable {
    case noDelimiters
    case unterminatedBody
    case malformedPart(String)
    case missingName
}

/// Reads a body back into parts, in the order they appear on the wire.
///
/// This is a fixture, not a general parser: it assumes CRLF framing and refuses
/// anything it does not understand rather than guessing, which is what makes a
/// round-trip assertion mean something.
enum MultipartFixtureParser {
    private static let crlf = Data("\r\n".utf8)
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    static func parse(_ body: MultipartFormBody) throws -> [MultipartPart] {
        try parse(body.data, boundary: body.boundary)
    }

    static func parse(_ data: Data, boundary: String) throws -> [MultipartPart] {
        let delimiter = Data("--\(boundary)".utf8)
        var delimiters: [Range<Data.Index>] = []
        var cursor = data.startIndex
        while let found = data.range(of: delimiter, in: cursor..<data.endIndex) {
            delimiters.append(found)
            cursor = found.upperBound
        }
        guard delimiters.count >= 2 else { throw MultipartParseError.noDelimiters }

        // The last delimiter closes the body; everything before it opens a part.
        let closing = delimiters[delimiters.count - 1]
        guard data[closing.upperBound...].elementsEqual(Data("--\r\n".utf8)) else {
            throw MultipartParseError.unterminatedBody
        }

        var parts: [MultipartPart] = []
        for (index, delimiter) in delimiters.dropLast().enumerated() {
            let segment = data[delimiter.upperBound..<delimiters[index + 1].lowerBound]
            parts.append(try parsePart(Data(segment)))
        }
        return parts
    }

    /// `segment` is everything between the opening delimiter and the next one:
    /// CRLF, headers, a blank line, the payload, and a trailing CRLF.
    private static func parsePart(_ segment: Data) throws -> MultipartPart {
        guard segment.starts(with: crlf), segment.count >= 4, segment.suffix(2) == crlf else {
            throw MultipartParseError.malformedPart("a part must be framed by CRLF")
        }
        let framed = segment.dropFirst(2).dropLast(2)
        guard let split = framed.range(of: headerTerminator) else {
            throw MultipartParseError.malformedPart("a part must have a blank line after its headers")
        }
        let headers = parseHeaders(String(decoding: framed[..<split.lowerBound], as: UTF8.self))
        guard let disposition = headers["content-disposition"] else {
            throw MultipartParseError.malformedPart("a part must carry Content-Disposition")
        }
        guard let name = parameter("name", in: disposition) else { throw MultipartParseError.missingName }
        return MultipartPart(
            name: name,
            filename: parameter("filename", in: disposition),
            contentType: headers["content-type"],
            body: Data(framed[split.upperBound...])
        )
    }

    private static func parseHeaders(_ block: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in block.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return headers
    }

    /// Pulls `name="value"` out of a Content-Disposition header. Quoted values
    /// only, which is all the encoder produces.
    private static func parameter(_ key: String, in header: String) -> String? {
        guard let start = header.range(of: "\(key)=\"") else { return nil }
        guard let end = header.range(of: "\"", range: start.upperBound..<header.endIndex) else { return nil }
        return String(header[start.upperBound..<end.lowerBound])
    }
}

extension Array where Element == MultipartPart {
    /// The first part with this field name, or `nil`.
    subscript(field name: String) -> MultipartPart? {
        first { $0.name == name }
    }

    var fieldNames: [String] { map(\.name) }
}
