// ABOUTME: Proves a watch capture survives the WCSession dictionary intact, and that junk does not.
// ABOUTME: The wrist's id and occurred_at crossing unchanged is Phase 3 success condition 1.

import Foundation
import Testing

@testable import MindGrapesKit

/// `transferUserInfo` carries a property-list dictionary, not `Data`, so the
/// payload converts both ways by hand. These tests are the contract for that
/// conversion.
@Suite
struct WatchCapturePayloadTests {
    private let id = UUID(uuidString: "5C4F1B2E-0000-4000-8000-000000000001")!
    private let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Every field survives the round trip")
    func roundTripsFully() throws {
        let coordinate = Coordinate(latitude: 39.9526, longitude: -75.1652)
        let payload = try #require(
            WatchCapturePayload(id: id, content: "the vet moved", occurredAt: occurredAt, coordinate: coordinate)
        )

        let decoded = try #require(WatchCapturePayload(userInfo: payload.userInfo))

        #expect(decoded == payload)
        #expect(decoded.id == id)
        #expect(decoded.content == "the vet moved")
        #expect(decoded.occurredAt == occurredAt)
        #expect(decoded.coordinate == coordinate)
    }

    /// The common case on a wrist with location off or a fix that timed out. A
    /// capture with no coordinate is a whole capture, not a degraded one.
    @Test("A payload with no coordinate round trips")
    func roundTripsWithoutCoordinate() throws {
        let payload = try #require(
            WatchCapturePayload(id: id, content: "no fix", occurredAt: occurredAt, coordinate: nil)
        )

        let decoded = try #require(WatchCapturePayload(userInfo: payload.userInfo))

        #expect(decoded.coordinate == nil)
        #expect(decoded == payload)
    }

    @Test("The dictionary carries only property-list types")
    func userInfoIsPropertyListSafe() throws {
        let coordinate = Coordinate(latitude: 1, longitude: 2)
        let payload = try #require(
            WatchCapturePayload(id: id, content: "plist", occurredAt: occurredAt, coordinate: coordinate)
        )

        // transferUserInfo rejects a dictionary holding anything else, at runtime,
        // with an exception rather than an error return.
        #expect(PropertyListSerialization.propertyList(payload.userInfo, isValidFor: .binary))
    }

    @Test("Content is trimmed on the way in")
    func contentIsTrimmed() throws {
        let payload = try #require(
            WatchCapturePayload(id: id, content: "  spaced  ", occurredAt: occurredAt, coordinate: nil)
        )

        #expect(payload.content == "spaced")
    }

    @Test("Blank content is refused at construction")
    func blankContentIsRefused() {
        #expect(WatchCapturePayload(id: id, content: "", occurredAt: occurredAt, coordinate: nil) == nil)
        #expect(WatchCapturePayload(id: id, content: "   \n ", occurredAt: occurredAt, coordinate: nil) == nil)
    }

    @Test("Blank content in a dictionary is refused too")
    func blankContentInDictionaryIsRefused() {
        let userInfo: [String: Any] = [
            "id": id.uuidString,
            "content": "  ",
            "occurredAt": occurredAt,
        ]

        #expect(WatchCapturePayload(userInfo: userInfo) == nil)
    }

    @Test("A missing or malformed id is refused")
    func badIdIsRefused() {
        let base: [String: Any] = ["content": "text", "occurredAt": occurredAt]

        #expect(WatchCapturePayload(userInfo: base) == nil)
        #expect(WatchCapturePayload(userInfo: base.merging(["id": "not-a-uuid"]) { _, new in new }) == nil)
        #expect(WatchCapturePayload(userInfo: base.merging(["id": 42]) { _, new in new }) == nil)
    }

    @Test("A missing occurredAt is refused rather than defaulted to now")
    func missingOccurredAtIsRefused() {
        // Defaulting would silently record when the phone caught up instead of when
        // the user spoke, which is the whole point of stamping it on the wrist.
        let userInfo: [String: Any] = ["id": id.uuidString, "content": "text"]

        #expect(WatchCapturePayload(userInfo: userInfo) == nil)
    }

    /// `Coordinate` is both-or-neither by construction (SPEC 6.3), so a dictionary
    /// carrying one half must not produce a coordinate at all.
    @Test("Half a coordinate yields no coordinate, not a bogus one")
    func halfCoordinateIsDropped() throws {
        let userInfo: [String: Any] = [
            "id": id.uuidString,
            "content": "text",
            "occurredAt": occurredAt,
            "latitude": 39.9526,
        ]

        let decoded = try #require(WatchCapturePayload(userInfo: userInfo))

        #expect(decoded.coordinate == nil)
    }

    /// An out-of-range pair is a bug or a corrupted transfer, and the server answers
    /// `400` for it. Dropping the coordinate keeps the capture, which matters more.
    @Test("An out-of-range coordinate is dropped, and the capture survives")
    func outOfRangeCoordinateIsDropped() throws {
        let userInfo: [String: Any] = [
            "id": id.uuidString,
            "content": "text",
            "occurredAt": occurredAt,
            "latitude": 91.0,
            "longitude": 0.0,
        ]

        let decoded = try #require(WatchCapturePayload(userInfo: userInfo))

        #expect(decoded.coordinate == nil)
        #expect(decoded.content == "text")
    }

    /// Forward compatibility in the direction that actually happens: watchOS and
    /// iOS update independently, so a newer wrist can hand an older phone a key it
    /// has never heard of.
    @Test("An unknown key is ignored")
    func unknownKeysAreIgnored() throws {
        let coordinate = Coordinate(latitude: 1, longitude: 2)
        let payload = try #require(
            WatchCapturePayload(id: id, content: "text", occurredAt: occurredAt, coordinate: coordinate)
        )
        var userInfo = payload.userInfo
        userInfo["somethingFromTheFuture"] = "ignored"

        #expect(WatchCapturePayload(userInfo: userInfo) == payload)
    }
}
