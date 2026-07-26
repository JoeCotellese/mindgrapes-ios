// ABOUTME: Proves a watch handoff becomes exactly one durable capture, with the wrist's own timestamp.
// ABOUTME: Runs over a real CaptureQueue and store, because the idempotency claim is about the store.

import Foundation
import SwiftData
import Testing

@testable import MindGrapesKit

/// Serialized for the same reason ``CaptureQueueTests`` is: every test opens a
/// store, and concurrent `ModelContainer` schema setup segfaults CoreData.
@Suite(.serialized)
struct WatchCaptureReceiverTests {
    private final class Fixture {
        let directory: URL
        let container: ModelContainer
        let appGroup: AppGroupContainer
        let queue: CaptureQueue

        init() throws {
            directory = URL.temporaryDirectory.appending(path: "MindGrapesWatchReceiverTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            container = try ModelContainer(
                for: CaptureRecord.self,
                configurations: ModelConfiguration(url: directory.appending(path: "captures.store"))
            )
            appGroup = AppGroupContainer(rootURL: directory)
            try appGroup.prepareDirectories()
            queue = CaptureQueue(container: container, appGroup: appGroup)
        }

        func records() throws -> [CaptureRecord] {
            try ModelContext(container).fetch(FetchDescriptor<CaptureRecord>())
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// Records whether it was asked, so "the receiver never geocodes a capture with
    /// no coordinate" is an assertion and not an assumption.
    private actor SpyGeocoder: ReverseGeocoding {
        private(set) var requests: [Coordinate] = []
        private let label: String?
        private let hangs: Bool

        init(label: String?, hangs: Bool = false) {
            self.label = label
            self.hangs = hangs
        }

        func placeLabel(for coordinate: Coordinate) async -> String? {
            requests.append(coordinate)
            if hangs {
                try? await Task.sleep(for: .seconds(60))
                return nil
            }
            return label
        }

        func requestCount() -> Int { requests.count }
    }

    private let wristID = UUID(uuidString: "9E2A77C1-0000-4000-8000-00000000ABCD")!
    private let spokenAt = Date(timeIntervalSince1970: 1_600_000_000)
    private let receivedAt = Date(timeIntervalSince1970: 1_600_009_999)

    private func payload(coordinate: Coordinate?) throws -> WatchCapturePayload {
        try #require(
            WatchCapturePayload(
                id: wristID,
                content: "the vet appointment moved",
                occurredAt: spokenAt,
                coordinate: coordinate
            )
        )
    }

    /// Phase 3 success condition 1: the capture lands with the *Watch's*
    /// `occurred_at` and coordinates, not the phone's at receive time.
    @Test func aHandoffBecomesARecordCarryingTheWristsOwnIdentity() async throws {
        let fixture = try Fixture()
        let receiver = WatchCaptureReceiver(queue: fixture.queue)
        let coordinate = try #require(Coordinate(latitude: 39.9526, longitude: -75.1652))

        let outcome = await receiver.receive(
            userInfo: try payload(coordinate: coordinate).userInfo,
            now: receivedAt
        )

        #expect(outcome == .enqueued(wristID))
        let record = try #require(try fixture.records().first)
        #expect(record.id == wristID)
        #expect(record.occurredAt == spokenAt)
        #expect(record.occurredAt != receivedAt)
        #expect(record.coordinate == coordinate)
        #expect(record.content == "the vet appointment moved")
        #expect(record.state == .pending)
    }

    /// `transferUserInfo` retries until the counterpart acknowledges, so the same
    /// payload arriving twice is expected traffic, not a bug.
    @Test func aRedeliveredHandoffIsADuplicateAndLeavesOneRecord() async throws {
        let fixture = try Fixture()
        let receiver = WatchCaptureReceiver(queue: fixture.queue)
        let userInfo = try payload(coordinate: nil).userInfo

        let first = await receiver.receive(userInfo: userInfo, now: receivedAt)
        let second = await receiver.receive(userInfo: userInfo, now: receivedAt)

        #expect(first == .enqueued(wristID))
        #expect(second == .duplicate(wristID))
        #expect(try fixture.records().count == 1)
    }

    @Test func anUnrecognizedDictionaryEnqueuesNothing() async throws {
        let fixture = try Fixture()
        let receiver = WatchCaptureReceiver(queue: fixture.queue)

        let outcome = await receiver.receive(userInfo: ["unexpected": "shape"], now: receivedAt)

        #expect(outcome == .rejected(reason: "malformed_payload"))
        #expect(try fixture.records().isEmpty)
    }

    @Test func aCoordinateGetsThePhonesPlaceLabel() async throws {
        let fixture = try Fixture()
        let geocoder = SpyGeocoder(label: "Kelly Drive")
        let receiver = WatchCaptureReceiver(queue: fixture.queue, geocoder: geocoder)
        let coordinate = try #require(Coordinate(latitude: 39.9526, longitude: -75.1652))

        _ = await receiver.receive(userInfo: try payload(coordinate: coordinate).userInfo, now: receivedAt)

        #expect(try fixture.records().first?.placeLabel == "Kelly Drive")
        #expect(await geocoder.requestCount() == 1)
    }

    /// SPEC 9: a geocode failure is not a location failure. The coordinate is the
    /// fix; the label is a nicety.
    @Test func aGeocodeThatFindsNothingStillLeavesTheCoordinate() async throws {
        let fixture = try Fixture()
        let receiver = WatchCaptureReceiver(queue: fixture.queue, geocoder: SpyGeocoder(label: nil))
        let coordinate = try #require(Coordinate(latitude: 39.9526, longitude: -75.1652))

        let outcome = await receiver.receive(
            userInfo: try payload(coordinate: coordinate).userInfo,
            now: receivedAt
        )

        #expect(outcome == .enqueued(wristID))
        let record = try #require(try fixture.records().first)
        #expect(record.coordinate == coordinate)
        #expect(record.placeLabel == nil)
    }

    @Test func aCaptureWithNoCoordinateIsNeverGeocoded() async throws {
        let fixture = try Fixture()
        let geocoder = SpyGeocoder(label: "Should Not Be Asked")
        let receiver = WatchCaptureReceiver(queue: fixture.queue, geocoder: geocoder)

        _ = await receiver.receive(userInfo: try payload(coordinate: nil).userInfo, now: receivedAt)

        #expect(await geocoder.requestCount() == 0)
        #expect(try fixture.records().first?.placeLabel == nil)
    }

    /// The receiver runs inside a `WCSession` delivery callback, which the system
    /// does not wait on indefinitely. A hung geocoder must cost the label and
    /// nothing else — and the record has to already be durable when the geocode is
    /// attempted, which is why enqueue happens first.
    @Test func aHungGeocoderCostsTheLabelAndNotTheCapture() async throws {
        let fixture = try Fixture()
        let receiver = WatchCaptureReceiver(
            queue: fixture.queue,
            geocoder: SpyGeocoder(label: "Never Arrives", hangs: true),
            geocodeBudget: .milliseconds(50)
        )
        let coordinate = try #require(Coordinate(latitude: 39.9526, longitude: -75.1652))

        let outcome = await receiver.receive(
            userInfo: try payload(coordinate: coordinate).userInfo,
            now: receivedAt
        )

        #expect(outcome == .enqueued(wristID))
        let record = try #require(try fixture.records().first)
        #expect(record.placeLabel == nil)
        #expect(record.coordinate == coordinate)
    }

    /// The phone's location toggle is off, so no geocoder is supplied at all. The
    /// capture still lands; it just carries whatever the wrist sent.
    @Test func noGeocoderStillEnqueues() async throws {
        let fixture = try Fixture()
        let receiver = WatchCaptureReceiver(queue: fixture.queue, geocoder: nil)
        let coordinate = try #require(Coordinate(latitude: 39.9526, longitude: -75.1652))

        let outcome = await receiver.receive(
            userInfo: try payload(coordinate: coordinate).userInfo,
            now: receivedAt
        )

        #expect(outcome == .enqueued(wristID))
        #expect(try fixture.records().first?.placeLabel == nil)
    }
}
