// ABOUTME: Byte-for-byte and round-trip coverage of the two capture-door encoders.
// ABOUTME: SPEC 6.3 and 6.4 are the contract; these tests are what stops a silent drift from it.

import Foundation
import Testing

@testable import MindGrapesKit

// MARK: - Shared fixtures

/// A fixed identifier so `idempotency_key` assertions read as literals.
private let fixedID = UUID(uuidString: "8B9F6A2E-0000-4000-8000-000000000001")!

/// 2025-07-23T16:03:11Z, which is 12:03:11-04:00 in `newYork`.
private let occurredAt = Date(timeIntervalSince1970: 1_753_286_591)

private let newYork = TimeZone(identifier: "America/New_York")!

/// Stand-in for the downscaled JPEG. Short and printable so a byte-for-byte
/// expectation stays readable.
private let imageBytes = Data("JPEGBYTES".utf8)

private let testBoundary = "MindGrapesTestBoundary"

/// Joins CRLF-framed lines the way multipart/form-data does, trailing CRLF included.
private func crlf(_ lines: [String]) -> Data {
    Data(lines.map { $0 + "\r\n" }.joined().utf8)
}

private func fullPhotoRecord() throws -> CaptureRecord {
    let draft = try #require(
        PhotoDraft(
            imageFilename: "A1B2.jpg",
            description: "A bag of dog food.",
            ocrText: "Ingredients: chicken",
            event: "Grocery run",
            occurredAt: occurredAt,
            coordinate: Coordinate(latitude: 39.9526, longitude: -75.1652),
            placeLabel: "Wegmans, Cherry Hill",
            people: [Person(name: "Anna", relationship: "neighbour")].compactMap { $0 },
            labels: ["groceries", "dog"]
        )
    )
    return CaptureRecord(id: fixedID, photo: draft)
}

private func fullNoteRecord() throws -> CaptureRecord {
    let draft = try #require(
        NoteDraft(
            content: "Met Lung at the LIFT Labs demo; he wants a follow-up.",
            occurredAt: occurredAt,
            coordinate: Coordinate(latitude: 39.9526, longitude: -75.1652),
            placeLabel: "Comcast Center, Philadelphia",
            people: [Person(name: "Lung", relationship: "colleague")].compactMap { $0 },
            labels: ["lift-labs"]
        )
    )
    return CaptureRecord(id: fixedID, note: draft)
}

private func encodeImage(
    _ record: CaptureRecord,
    imageData: Data = imageBytes,
    boundary: String? = testBoundary
) throws -> MultipartFormBody {
    try CaptureWireEncoder.imageMultipartBody(
        for: record,
        imageData: imageData,
        timeZone: newYork,
        boundary: boundary
    )
}

private func encodeNote(_ record: CaptureRecord) throws -> Data {
    try CaptureWireEncoder.noteBody(for: record, timeZone: newYork)
}

/// Decodes the body as a dictionary so tests can assert per key without pinning order.
private func noteFields(_ data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

// MARK: - POST /capture/image

@Suite struct ImageMultipartEncodingTests {
    @Test func producesExactlyTheDocumentedBytes() throws {
        let body = try encodeImage(try fullPhotoRecord())

        let expected = crlf([
            "--\(testBoundary)",
            #"Content-Disposition: form-data; name="image"; filename="A1B2.jpg""#,
            "Content-Type: image/jpeg",
            "",
            "JPEGBYTES",
            "--\(testBoundary)",
            #"Content-Disposition: form-data; name="description""#,
            "",
            "A bag of dog food.",
            "--\(testBoundary)",
            #"Content-Disposition: form-data; name="ocr_text""#,
            "",
            "Ingredients: chicken",
            "--\(testBoundary)",
            #"Content-Disposition: form-data; name="occurred_at""#,
            "",
            "2025-07-23T12:03:11-04:00",
            "--\(testBoundary)",
            #"Content-Disposition: form-data; name="event""#,
            "",
            "Grocery run",
            "--\(testBoundary)",
            #"Content-Disposition: form-data; name="visibility""#,
            "",
            "private",
            "--\(testBoundary)",
            #"Content-Disposition: form-data; name="lat""#,
            "",
            "39.9526",
            "--\(testBoundary)",
            #"Content-Disposition: form-data; name="lng""#,
            "",
            "-75.1652",
            "--\(testBoundary)",
            #"Content-Disposition: form-data; name="people""#,
            "",
            #"[{"name":"Anna","relationship":"neighbour"}]"#,
            "--\(testBoundary)",
            #"Content-Disposition: form-data; name="labels""#,
            "",
            #"["groceries","dog"]"#,
            "--\(testBoundary)",
            #"Content-Disposition: form-data; name="idempotency_key""#,
            "",
            "8B9F6A2E-0000-4000-8000-000000000001",
            "--\(testBoundary)--",
        ])

        #expect(body.data == expected)
        #expect(body.boundary == testBoundary)
        #expect(body.contentType == "multipart/form-data; boundary=\(testBoundary)")
    }

    @Test func partsAppearInTheOrderSpec63ListsThem() throws {
        let parts = try MultipartFixtureParser.parse(try encodeImage(try fullPhotoRecord()))
        #expect(
            parts.fieldNames == [
                "image", "description", "ocr_text", "occurred_at", "event",
                "visibility", "lat", "lng", "people", "labels", "idempotency_key",
            ]
        )
    }

    @Test func everyFieldSurvivesTheRoundTrip() throws {
        let parts = try MultipartFixtureParser.parse(try encodeImage(try fullPhotoRecord()))

        let image = try #require(parts[field: "image"])
        #expect(image.body == imageBytes)
        #expect(image.filename == "A1B2.jpg")
        #expect(image.contentType == "image/jpeg")

        #expect(parts[field: "description"]?.text == "A bag of dog food.")
        #expect(parts[field: "ocr_text"]?.text == "Ingredients: chicken")
        #expect(parts[field: "occurred_at"]?.text == "2025-07-23T12:03:11-04:00")
        #expect(parts[field: "event"]?.text == "Grocery run")
        #expect(parts[field: "visibility"]?.text == "private")
        #expect(parts[field: "lat"]?.text == "39.9526")
        #expect(parts[field: "lng"]?.text == "-75.1652")
        #expect(parts[field: "idempotency_key"]?.text == fixedID.uuidString)

        let people = try JSONDecoder().decode([Person].self, from: try #require(parts[field: "people"]).body)
        #expect(people == [Person(name: "Anna", relationship: "neighbour")].compactMap { $0 })

        let labels = try JSONDecoder().decode([String].self, from: try #require(parts[field: "labels"]).body)
        #expect(labels == ["groceries", "dog"])
    }

    @Test func omitsOptionalFieldsThatHaveNoValue() throws {
        let draft = try #require(PhotoDraft(imageFilename: "A1B2.jpg", description: "A label.", occurredAt: occurredAt))
        let parts = try MultipartFixtureParser.parse(try encodeImage(CaptureRecord(id: fixedID, photo: draft)))

        #expect(parts.fieldNames == ["image", "description", "occurred_at", "visibility", "idempotency_key"])
    }

    @Test func omitsWhitespaceOnlyOptionalText() throws {
        // The drafts already trim, so reach the record through the designated
        // initializer, which is the path a rehydrated or hand-built record takes.
        let record = CaptureRecord(
            id: fixedID,
            kind: .photo,
            occurredAt: occurredAt,
            captureDescription: "A label.",
            ocrText: "   ",
            event: "\n\t",
            imageFilename: "A1B2.jpg"
        )
        let parts = try MultipartFixtureParser.parse(try encodeImage(record))
        #expect(parts[field: "ocr_text"] == nil)
        #expect(parts[field: "event"] == nil)
    }

    @Test func alwaysSendsOccurredAtAndPrivateVisibility() throws {
        // SPEC 6.3: downscaling strips the EXIF the server would fall back to,
        // so an absent `occurred_at` silently dates the capture to nothing.
        // SPEC 11: the client never offers `shared`.
        let draft = try #require(PhotoDraft(imageFilename: "A1B2.jpg", description: "A label.", occurredAt: occurredAt))
        let parts = try MultipartFixtureParser.parse(try encodeImage(CaptureRecord(id: fixedID, photo: draft)))
        #expect(parts[field: "occurred_at"]?.text == "2025-07-23T12:03:11-04:00")
        #expect(parts[field: "visibility"]?.text == "private")
    }

    // MARK: Location

    @Test func sendsLatitudeAndLongitudeTogetherOrNotAtAll() throws {
        let withFix = try MultipartFixtureParser.parse(try encodeImage(try fullPhotoRecord()))
        #expect(withFix[field: "lat"] != nil)
        #expect(withFix[field: "lng"] != nil)

        let record = try fullPhotoRecord()
        record.coordinate = nil
        let withoutFix = try MultipartFixtureParser.parse(try encodeImage(record))
        #expect(withoutFix[field: "lat"] == nil)
        #expect(withoutFix[field: "lng"] == nil)
    }

    @Test func aHalfSetFixSendsNeitherField() throws {
        // `Coordinate` makes a half-set fix unrepresentable through the public
        // API, so this reaches past it to the stored halves: that is the only
        // path (a legacy row, a partial write) that could still express one.
        let record = try fullPhotoRecord()
        record.lat = 39.9526
        record.lng = nil
        let parts = try MultipartFixtureParser.parse(try encodeImage(record))
        #expect(parts[field: "lat"] == nil)
        #expect(parts[field: "lng"] == nil)

        record.lat = nil
        record.lng = -75.1652
        let mirrored = try MultipartFixtureParser.parse(try encodeImage(record))
        #expect(mirrored[field: "lat"] == nil)
        #expect(mirrored[field: "lng"] == nil)
    }

    @Test func formatsDegreesSoTheServersFloatParseSeesTheSameNumber() throws {
        let record = try fullPhotoRecord()
        record.coordinate = Coordinate(latitude: -33.868_820_1, longitude: 151.209_290_5)
        let parts = try MultipartFixtureParser.parse(try encodeImage(record))
        #expect(Double(try #require(parts[field: "lat"]).text) == -33.868_820_1)
        #expect(Double(try #require(parts[field: "lng"]).text) == 151.209_290_5)
        // No exponent notation, which Python's float() accepts but which reads
        // as a bug in a request log.
        #expect(!(parts[field: "lat"]?.text.contains("e") ?? true))
    }

    @Test func aFixNearZeroAvoidsExponentNotation() throws {
        // Swift's shortest round-tripping form of a small double is `1e-05`.
        // Python's float() reads it, but a fix on the prime meridian should not
        // look like a serialization accident in a request log.
        let record = try fullPhotoRecord()
        record.coordinate = Coordinate(latitude: 0.000_01, longitude: -0.000_002)
        let parts = try MultipartFixtureParser.parse(try encodeImage(record))
        #expect(parts[field: "lat"]?.text == "0.0000100000")
        #expect(parts[field: "lng"]?.text == "-0.0000020000")
        #expect(Double(try #require(parts[field: "lat"]).text) == 0.000_01)
        #expect(Double(try #require(parts[field: "lng"]).text) == -0.000_002)
    }

    // MARK: People and labels

    @Test func peopleAndLabelsUseTheJSONArrayForm() throws {
        let parts = try MultipartFixtureParser.parse(try encodeImage(try fullPhotoRecord()))
        #expect(parts[field: "people"]?.text.hasPrefix("[") == true)
        #expect(parts[field: "labels"]?.text.hasPrefix("[") == true)
    }

    @Test func aNameContainingACommaSurvives() throws {
        // The whole reason SPEC 6.3 tells the client to avoid the comma-separated
        // form: it cannot carry this name.
        let record = try fullPhotoRecord()
        record.people = [Person(name: "Smith, Jr., Bob"), Person(name: "Anna")].compactMap { $0 }
        let parts = try MultipartFixtureParser.parse(try encodeImage(record))
        let people = try JSONDecoder().decode([Person].self, from: try #require(parts[field: "people"]).body)
        #expect(people.map(\.name) == ["Smith, Jr., Bob", "Anna"])
    }

    @Test func aLabelContainingACommaSurvives() throws {
        let record = try fullPhotoRecord()
        record.labels = ["groceries, bulk", "dog"]
        let parts = try MultipartFixtureParser.parse(try encodeImage(record))
        let labels = try JSONDecoder().decode([String].self, from: try #require(parts[field: "labels"]).body)
        #expect(labels == ["groceries, bulk", "dog"])
    }

    @Test func aRelationshipIsCarriedOnThePersonObject() throws {
        let record = try fullPhotoRecord()
        record.people = [Person(name: "Anna", relationship: "neighbour"), Person(name: "Marco")]
            .compactMap { $0 }
        let parts = try MultipartFixtureParser.parse(try encodeImage(record))
        // The resolver takes the object verbatim, so an absent relationship is
        // an absent key rather than a null.
        #expect(
            parts[field: "people"]?.text == #"[{"name":"Anna","relationship":"neighbour"},{"name":"Marco"}]"#
        )
    }

    @Test func emptyPeopleAndLabelsAreOmittedEntirely() throws {
        let record = try fullPhotoRecord()
        record.people = []
        record.labels = []
        let parts = try MultipartFixtureParser.parse(try encodeImage(record))
        #expect(parts[field: "people"] == nil)
        #expect(parts[field: "labels"] == nil)
    }

    @Test func blankLabelsAreDroppedRatherThanSentEmpty() throws {
        let record = try fullPhotoRecord()
        record.labels = ["groceries", "  ", ""]
        let parts = try MultipartFixtureParser.parse(try encodeImage(record))
        let labels = try JSONDecoder().decode([String].self, from: try #require(parts[field: "labels"]).body)
        #expect(labels == ["groceries"])
    }

    // MARK: Unicode

    @Test func unicodeInContentAndNamesEncodesAsUTF8() throws {
        let record = try fullPhotoRecord()
        record.captureDescription = "Un caffè al bar — 日本のパン 🍇"
        record.ocrText = "Caffè, 250 g"
        record.people = [Person(name: "Zoë Müller-Ćirić"), Person(name: "山田 太郎")].compactMap { $0 }
        record.labels = ["café", "パン"]

        let parts = try MultipartFixtureParser.parse(try encodeImage(record))
        #expect(parts[field: "description"]?.text == "Un caffè al bar — 日本のパン 🍇")
        #expect(parts[field: "ocr_text"]?.text == "Caffè, 250 g")

        let people = try JSONDecoder().decode([Person].self, from: try #require(parts[field: "people"]).body)
        #expect(people.map(\.name) == ["Zoë Müller-Ćirić", "山田 太郎"])
        let labels = try JSONDecoder().decode([String].self, from: try #require(parts[field: "labels"]).body)
        #expect(labels == ["café", "パン"])

        // Raw UTF-8 on the wire, not \u escapes: the server reads the form with
        // the request charset, and escapes would arrive as literal backslashes
        // in the non-JSON parts.
        let description = try #require(parts[field: "description"])
        #expect(description.body == Data("Un caffè al bar — 日本のパン 🍇".utf8))
    }

    // MARK: Idempotency

    @Test func encodingTheSameRecordTwiceRepeatsTheIdempotencyKey() throws {
        // SPEC 6.5: minted with the record, reused verbatim on every retry. If
        // the encoder ever mints one, a retry duplicates the experience.
        let record = try fullPhotoRecord()
        let first = try MultipartFixtureParser.parse(try encodeImage(record))
        let second = try MultipartFixtureParser.parse(try encodeImage(record))
        #expect(first[field: "idempotency_key"]?.text == second[field: "idempotency_key"]?.text)
        #expect(first[field: "idempotency_key"]?.text == record.idempotencyKey)
    }

    @Test func idempotencyKeyIsSentEvenThoughTheServerMayIgnoreIt() throws {
        // SPEC 6.3: unknown form fields are ignored, so sending it early costs
        // nothing and turns the server-side change into a no-op for the client.
        let draft = try #require(PhotoDraft(imageFilename: "A1B2.jpg", description: "A label.", occurredAt: occurredAt))
        let parts = try MultipartFixtureParser.parse(try encodeImage(CaptureRecord(id: fixedID, photo: draft)))
        #expect(parts[field: "idempotency_key"]?.text == fixedID.uuidString)
    }

    // MARK: Boundaries

    @Test func aGeneratedBoundaryDoesNotAppearInThePayload() throws {
        let record = try fullPhotoRecord()
        let body = try encodeImage(record, boundary: nil)
        let parts = try MultipartFixtureParser.parse(body)
        for part in parts {
            #expect(part.body.range(of: Data(body.boundary.utf8)) == nil)
        }
        // Every part opens one delimiter and the body closes with one more.
        #expect(occurrences(of: "--\(body.boundary)", in: body.data) == parts.count + 1)
    }

    @Test func aBoundaryCollidingWithThePayloadIsRefused() throws {
        let record = try fullPhotoRecord()
        record.captureDescription = "The label reads --\(testBoundary) across the top."
        #expect(throws: CaptureEncodingError.boundaryCollision(testBoundary)) {
            _ = try encodeImage(record)
        }
    }

    @Test func aBoundaryCollidedByTheImageBytesIsRefused() throws {
        let record = try fullPhotoRecord()
        let colliding = Data("....\(testBoundary)....".utf8)
        #expect(throws: CaptureEncodingError.boundaryCollision(testBoundary)) {
            _ = try encodeImage(record, imageData: colliding)
        }
    }

    @Test func aGeneratedBoundaryStepsAroundAPayloadThatContainsOne() throws {
        // Generation retries rather than throwing, because a caller who did not
        // pick the boundary cannot do anything about a collision.
        let record = try fullPhotoRecord()
        record.captureDescription = "Contains \(MultipartFormBody.makeBoundary()) verbatim."
        let body = try encodeImage(record, boundary: nil)
        #expect(try MultipartFixtureParser.parse(body)[field: "description"]?.text == record.captureDescription)
    }

    @Test func generatedBoundariesAreDistinctAndLegal() {
        let boundaries = (0..<32).map { _ in MultipartFormBody.makeBoundary() }
        #expect(Set(boundaries).count == boundaries.count)
        for boundary in boundaries {
            #expect((1...70).contains(boundary.count))
            #expect(boundary.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-".contains($0) })
        }
    }

    @Test func anIllegalBoundaryIsRefused() throws {
        let record = try fullPhotoRecord()
        for boundary in ["", "has space", "has\"quote", String(repeating: "a", count: 71)] {
            #expect(throws: CaptureEncodingError.invalidBoundary(boundary)) {
                _ = try encodeImage(record, boundary: boundary)
            }
        }
    }

    // MARK: Refusals

    @Test func aNoteRecordIsNotAnImageUpload() throws {
        #expect(throws: CaptureEncodingError.wrongKind(expected: .photo, actual: .note)) {
            _ = try encodeImage(try fullNoteRecord())
        }
    }

    @Test func aPhotoRecordWithoutASpoolFilenameIsRefused() throws {
        let record = CaptureRecord(id: fixedID, kind: .photo, occurredAt: occurredAt, captureDescription: "A label.")
        #expect(throws: CaptureEncodingError.missingImageFilename) {
            _ = try encodeImage(record)
        }
    }

    @Test func aFilenameThatWouldBreakTheHeaderIsEscaped() throws {
        // Browsers percent-encode exactly these three in a filename; anything
        // else would let a filename forge a header or a delimiter.
        let record = try fullPhotoRecord()
        record.imageFilename = "we\"ird\r\none.jpg"
        let parts = try MultipartFixtureParser.parse(try encodeImage(record))
        #expect(parts[field: "image"]?.filename == "we%22ird%0D%0Aone.jpg")
    }
}

// MARK: - POST /capture/note

@Suite struct NoteBodyEncodingTests {
    @Test func producesExactlyTheDocumentedBytes() throws {
        let body = try encodeNote(try fullNoteRecord())
        let expected = """
            {"content":"Met Lung at the LIFT Labs demo; he wants a follow-up.",\
            "idempotency_key":"8B9F6A2E-0000-4000-8000-000000000001",\
            "labels":["lift-labs"],\
            "lat":39.9526,\
            "lng":-75.1652,\
            "occurred_at":"2025-07-23T12:03:11-04:00",\
            "people":[{"name":"Lung","relationship":"colleague"}],\
            "place_label":"Comcast Center, Philadelphia",\
            "visibility":"private"}
            """
        #expect(String(decoding: body, as: UTF8.self) == expected)
    }

    @Test func everyFieldSurvivesTheRoundTrip() throws {
        let fields = try noteFields(try encodeNote(try fullNoteRecord()))
        #expect(fields["content"] as? String == "Met Lung at the LIFT Labs demo; he wants a follow-up.")
        #expect(fields["occurred_at"] as? String == "2025-07-23T12:03:11-04:00")
        #expect(fields["lat"] as? Double == 39.9526)
        #expect(fields["lng"] as? Double == -75.1652)
        #expect(fields["place_label"] as? String == "Comcast Center, Philadelphia")
        #expect(fields["visibility"] as? String == "private")
        #expect(fields["idempotency_key"] as? String == fixedID.uuidString)
        #expect(fields["labels"] as? [String] == ["lift-labs"])

        let people = try #require(fields["people"] as? [[String: String]])
        #expect(people == [["name": "Lung", "relationship": "colleague"]])
    }

    @Test func omitsEveryOptionalFieldThatHasNoValue() throws {
        let draft = try #require(NoteDraft(content: "Buy dog food.", occurredAt: occurredAt))
        let fields = try noteFields(try encodeNote(CaptureRecord(id: fixedID, note: draft)))
        #expect(Set(fields.keys) == ["content", "occurred_at", "visibility", "idempotency_key"])
    }

    @Test func sendsLatitudeAndLongitudeTogetherOrNotAtAll() throws {
        let record = try fullNoteRecord()
        record.coordinate = nil
        let fields = try noteFields(try encodeNote(record))
        #expect(fields["lat"] == nil)
        #expect(fields["lng"] == nil)
    }

    @Test func aHalfSetFixSendsNeitherField() throws {
        let record = try fullNoteRecord()
        record.lat = 39.9526
        record.lng = nil
        var fields = try noteFields(try encodeNote(record))
        #expect(fields["lat"] == nil)
        #expect(fields["lng"] == nil)

        record.lat = nil
        record.lng = -75.1652
        fields = try noteFields(try encodeNote(record))
        #expect(fields["lat"] == nil)
        #expect(fields["lng"] == nil)
    }

    @Test func latitudeAndLongitudeAreJSONNumbers() throws {
        // SPEC 6.4's example body spells them as numbers, unlike the multipart
        // door where every value is a string.
        let text = String(decoding: try encodeNote(try fullNoteRecord()), as: UTF8.self)
        #expect(text.contains(#""lat":39.9526"#))
        #expect(text.contains(#""lng":-75.1652"#))
    }

    @Test func aNameContainingACommaSurvives() throws {
        let record = try fullNoteRecord()
        record.people = [Person(name: "Smith, Jr., Bob")].compactMap { $0 }
        let people = try #require(try noteFields(try encodeNote(record))["people"] as? [[String: String]])
        #expect(people == [["name": "Smith, Jr., Bob"]])
    }

    @Test func unicodeInContentAndNamesEncodesAsUTF8() throws {
        let record = try fullNoteRecord()
        record.content = "Preso un caffè con Zoë — 日本 🍇"
        record.people = [Person(name: "Zoë Müller-Ćirić", relationship: "collega")].compactMap { $0 }
        record.labels = ["viaggio", "パン"]

        let data = try encodeNote(record)
        // Raw UTF-8, not \u escapes.
        #expect(data.range(of: Data(#"\u"#.utf8)) == nil)

        let fields = try noteFields(data)
        #expect(fields["content"] as? String == "Preso un caffè con Zoë — 日本 🍇")
        #expect(fields["labels"] as? [String] == ["viaggio", "パン"])
        let people = try #require(fields["people"] as? [[String: String]])
        #expect(people == [["name": "Zoë Müller-Ćirić", "relationship": "collega"]])
    }

    @Test func encodingTheSameRecordTwiceRepeatsTheIdempotencyKey() throws {
        let record = try fullNoteRecord()
        #expect(try encodeNote(record) == (try encodeNote(record)))
        #expect(try noteFields(try encodeNote(record))["idempotency_key"] as? String == record.idempotencyKey)
    }

    @Test func alwaysSendsOccurredAtAndPrivateVisibility() throws {
        let fields = try noteFields(try encodeNote(try fullNoteRecord()))
        #expect(fields["occurred_at"] as? String == "2025-07-23T12:03:11-04:00")
        #expect(fields["visibility"] as? String == "private")
    }

    @Test func aPhotoRecordIsNotANote() throws {
        #expect(throws: CaptureEncodingError.wrongKind(expected: .note, actual: .photo)) {
            _ = try encodeNote(try fullPhotoRecord())
        }
    }

    @Test func aNoteWithoutContentIsRefused() throws {
        // `content` is the one required field on SPEC 6.4's body. `NoteDraft`
        // will not build one, but the designated initializer will.
        for content in [nil, "", "  \n"] {
            let record = CaptureRecord(id: fixedID, kind: .note, content: content, occurredAt: occurredAt)
            #expect(throws: CaptureEncodingError.missingContent) {
                _ = try encodeNote(record)
            }
        }
    }
}

// MARK: - Helpers

private func occurrences(of needle: String, in haystack: Data) -> Int {
    let pattern = Data(needle.utf8)
    var count = 0
    var cursor = haystack.startIndex
    while let found = haystack.range(of: pattern, in: cursor..<haystack.endIndex) {
        count += 1
        cursor = found.upperBound
    }
    return count
}
