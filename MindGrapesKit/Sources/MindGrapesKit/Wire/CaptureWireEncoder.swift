// ABOUTME: Turns a CaptureRecord into the exact bytes POST /capture/image and /capture/note expect.
// ABOUTME: The single place the wire shape lives, so a server-side change costs one file.

import Foundation

/// The wire encoders for both capture doors (SPEC 6.3, 6.4).
///
/// Pure functions over a record: no `URLRequest`, no session, no queue. Item 4
/// wraps the output in a request; item 5 decides when to hand a record over.
public enum CaptureWireEncoder {
    /// SPEC 6.3 accepts `private` or `shared`; SPEC 11 says this client only
    /// ever captures privately, so the value is a constant here rather than a
    /// field on the model somebody could set wrong.
    public static let visibility = "private"

    // MARK: - POST /capture/image

    /// Builds the multipart body for the photo door.
    ///
    /// The caller passes the spooled bytes because SPEC 8.1 keeps image data out
    /// of the database; the record only names the file.
    ///
    /// - Parameters:
    ///   - imageData: The downscaled derivative read from the spool.
    ///   - imageContentType: The part's declared type. SPEC 6.3: the server
    ///     never trusts it, deciding by whether Pillow can decode the bytes.
    ///     SPEC 7.2 downscales to JPEG, hence the default.
    ///   - timeZone: The zone `occurred_at` is expressed in. Defaults to the
    ///     device's, which is what makes the offset in the string mean something
    ///     to a human reading it later.
    ///   - boundary: `nil` generates one. Supplying one is for tests that assert
    ///     on bytes.
    public static func imageMultipartBody(
        for record: CaptureRecord,
        imageData: Data,
        imageContentType: String = "image/jpeg",
        timeZone: TimeZone = .current,
        boundary: String? = nil
    ) throws -> MultipartFormBody {
        guard record.kind == .photo else {
            throw CaptureEncodingError.wrongKind(expected: .photo, actual: record.kind)
        }
        guard let filename = record.imageFilename?.nonBlank else {
            throw CaptureEncodingError.missingImageFilename
        }

        // Field order follows SPEC 6.3's own listing. The server does not care,
        // but a fixed order is what lets a retry produce identical bytes and a
        // test assert on them.
        var builder = MultipartFormBuilder()
        builder.addFile("image", filename: filename, contentType: imageContentType, data: imageData)
        if let description = record.captureDescription?.nonBlank {
            builder.addField("description", description)
        }
        if let ocrText = record.ocrText?.nonBlank {
            builder.addField("ocr_text", ocrText)
        }
        // Never conditional: downscaling strips the EXIF `DateTimeOriginal` the
        // server would otherwise fall back to (SPEC 6.3).
        builder.addField("occurred_at", WireTimestamp.string(from: record.occurredAt, in: timeZone))
        if let event = record.event?.nonBlank {
            builder.addField("event", event)
        }
        builder.addField("visibility", visibility)
        // `coordinate` is the both-or-neither guarantee SPEC 6.3 requires; a row
        // with one half populated reads as `nil` and sends nothing.
        if let coordinate = record.coordinate {
            builder.addField("lat", degrees(coordinate.latitude))
            builder.addField("lng", degrees(coordinate.longitude))
        }
        if let people = try wirePeople(record.people) {
            builder.addField("people", people)
        }
        if let labels = try wireLabels(record.labels) {
            builder.addField("labels", labels)
        }
        // Sent even though the server may not read it yet: unknown form fields
        // are ignored, so this costs nothing and the server change lands as a
        // no-op for shipped clients (SPEC 6.3, 6.5).
        builder.addField("idempotency_key", record.idempotencyKey)

        return try builder.build(boundary: boundary)
    }

    // MARK: - POST /capture/note

    /// Builds the JSON body for the note door (SPEC 6.4).
    public static func noteBody(for record: CaptureRecord, timeZone: TimeZone = .current) throws -> Data {
        guard record.kind == .note else {
            throw CaptureEncodingError.wrongKind(expected: .note, actual: record.kind)
        }
        guard let content = record.content?.nonBlank else {
            throw CaptureEncodingError.missingContent
        }

        let coordinate = record.coordinate
        let body = NoteBody(
            content: content,
            occurredAt: WireTimestamp.string(from: record.occurredAt, in: timeZone),
            lat: coordinate?.latitude,
            lng: coordinate?.longitude,
            placeLabel: record.placeLabel?.nonBlank,
            people: nonEmptyWirePeople(record.people),
            labels: nonEmptyLabels(record.labels),
            visibility: visibility,
            idempotencyKey: record.idempotencyKey
        )
        return try jsonEncoder().encode(body)
    }

    // MARK: - Shared encoding

    /// SPEC 6.4's body, with the wire's snake-case names.
    ///
    /// `event` and `ocr_text` are absent on purpose: neither appears in the
    /// documented note shape, and inventing fields on an endpoint that does not
    /// exist yet is how a client and a server disagree.
    ///
    /// Optionals are omitted rather than sent as `null`, which is what the
    /// synthesized encoder does with `encodeIfPresent`.
    private struct NoteBody: Encodable {
        let content: String
        let occurredAt: String
        let lat: Double?
        let lng: Double?
        let placeLabel: String?
        let people: [WirePerson]?
        let labels: [String]?
        let visibility: String
        let idempotencyKey: String

        enum CodingKeys: String, CodingKey {
            case content
            case occurredAt = "occurred_at"
            case lat
            case lng
            case placeLabel = "place_label"
            case people
            case labels
            case visibility
            case idempotencyKey = "idempotency_key"
        }
    }

    /// The participant shape the server's resolver takes verbatim (SPEC 6.3).
    ///
    /// Deliberately not `Person` itself: `Person` is also what SwiftData persists,
    /// and a field added there for local use must not leak onto the wire.
    private struct WirePerson: Encodable {
        let name: String
        let relationship: String?
    }

    /// Sorted keys because a retry must produce the same bytes as the first
    /// attempt; unescaped slashes because a URL in a note should be readable in
    /// a request log.
    private static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func nonEmptyWirePeople(_ people: [Person]) -> [WirePerson]? {
        let wire = people.map { WirePerson(name: $0.name, relationship: $0.relationship) }
        return wire.isEmpty ? nil : wire
    }

    private static func nonEmptyLabels(_ labels: [String]) -> [String]? {
        let kept = labels.compactMap(\.nonBlank)
        return kept.isEmpty ? nil : kept
    }

    /// SPEC 6.3: the JSON-array form exclusively. The comma-separated form the
    /// server also accepts cannot carry a name containing a comma.
    private static func wirePeople(_ people: [Person]) throws -> String? {
        guard let wire = nonEmptyWirePeople(people) else { return nil }
        return String(decoding: try jsonEncoder().encode(wire), as: UTF8.self)
    }

    private static func wireLabels(_ labels: [String]) throws -> String? {
        guard let kept = nonEmptyLabels(labels) else { return nil }
        return String(decoding: try jsonEncoder().encode(kept), as: UTF8.self)
    }

    /// Decimal degrees for the multipart door, where every value is a string.
    ///
    /// The shortest round-tripping form is the default, so a fix reads the same
    /// on the wire as it does in the debugger. Near the equator or the prime
    /// meridian that form is exponential (`1e-05`); Python's `float()` parses it,
    /// but it reads as a bug in a request log, so those fall back to plain
    /// decimals well past any precision a GPS fix carries.
    private static func degrees(_ value: Double) -> String {
        let shortest = String(value)
        guard shortest.lowercased().contains("e") else { return shortest }
        // `locale: nil` spelled out: the localizing overload of `String(format:)`
        // would write `0,0000100000` on an Italian device, and the server's
        // `float()` would answer `400`.
        return String(format: "%.10f", locale: nil, value)
    }
}
