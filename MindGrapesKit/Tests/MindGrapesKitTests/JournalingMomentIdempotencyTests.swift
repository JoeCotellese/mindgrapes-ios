// ABOUTME: Proves a re-pulled Journaling Suggestion derives the same id, so it dedupes.
// ABOUTME: Group order, accent form, and the coordinate must not change the id, or a re-pull would duplicate.

import Foundation
import SwiftData
import Testing

@testable import MindGrapesKit

/// The idempotency id is derived, not random, because Apple's picker exposes no
/// stable suggestion id outside the notification flow. These tests are the
/// contract for that derivation: what must and must not change the id.
@Suite
struct JournalingMomentIdempotencyTests {
    private let visitDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("The same moment derives the same id every time")
    func deterministic() {
        let a = JournalingMoment(
            content: .location(place: "Colosseo", city: "Roma"), date: visitDate, coordinate: nil
        )
        let b = JournalingMoment(
            content: .location(place: "Colosseo", city: "Roma"), date: visitDate, coordinate: nil
        )

        #expect(a.idempotencyID == b.idempotencyID)
    }

    /// The load-bearing property: the display text keeps Apple's order, but the id
    /// must not, or the same outing re-pulled in a different order would enqueue a
    /// second memory (#52's no-duplicate rule).
    @Test("Group place order does not change the id")
    func groupOrderInvariant() {
        let forward = JournalingMoment(
            content: .locationGroup(city: "Firenze", places: ["Duomo", "Ponte Vecchio", "Uffizi"]),
            date: visitDate, coordinate: nil
        )
        let shuffled = JournalingMoment(
            content: .locationGroup(city: "Firenze", places: ["Uffizi", "Duomo", "Ponte Vecchio"]),
            date: visitDate, coordinate: nil
        )

        #expect(forward.idempotencyID == shuffled.idempotencyID)
    }

    @Test("Duplicate places in a group do not change the id")
    func groupDuplicateInvariant() {
        let plain = JournalingMoment(
            content: .locationGroup(city: "Firenze", places: ["Duomo", "Uffizi"]),
            date: visitDate, coordinate: nil
        )
        let repeated = JournalingMoment(
            content: .locationGroup(city: "Firenze", places: ["Duomo", "duomo", "Uffizi", "Duomo"]),
            date: visitDate, coordinate: nil
        )

        #expect(plain.idempotencyID == repeated.idempotencyID)
    }

    @Test("Case and surrounding whitespace do not change the id")
    func normalizedInputsMatch() {
        let a = JournalingMoment(
            content: .location(place: "Galleria dell'Accademia", city: "Firenze"),
            date: visitDate, coordinate: nil
        )
        let b = JournalingMoment(
            content: .location(place: "  galleria dell'accademia ", city: " FIRENZE "),
            date: visitDate, coordinate: nil
        )

        #expect(a.idempotencyID == b.idempotencyID)
    }

    /// The core Italian case: CoreLocation can hand back an accented name composed
    /// (à = U+00E0) one pull and decomposed (a + U+0300) the next. Swift compares
    /// them equal, but their UTF-8 bytes differ, so without NFC folding the re-pull
    /// would derive a different id and duplicate.
    @Test("An accent composed vs decomposed derives the same id")
    func unicodeNormalizationInvariant() {
        let precomposed = JournalingMoment(
            content: .location(place: "Citt\u{00E0} di Castello", city: "Perugia"),
            date: visitDate, coordinate: nil
        )
        let decomposed = JournalingMoment(
            content: .location(place: "Citta\u{0300} di Castello", city: "Perugia"),
            date: visitDate, coordinate: nil
        )

        #expect(precomposed.idempotencyID == decomposed.idempotencyID)
    }

    /// Apple sometimes qualifies the place with its city and leaves `city` nil, and
    /// sometimes splits them. Both render the same note, so both must key the same
    /// or the same visit lands twice.
    @Test("Place-carries-city and split-city derive the same id")
    func placeCarriesCityInvariant() {
        let qualified = JournalingMoment(
            content: .location(place: "Galleria dell'Accademia, Firenze", city: nil),
            date: visitDate, coordinate: nil
        )
        let split = JournalingMoment(
            content: .location(place: "Galleria dell'Accademia", city: "Firenze"),
            date: visitDate, coordinate: nil
        )

        #expect(qualified.idempotencyID == split.idempotencyID)
    }

    @Test("A place that is its own city derives the same id with or without the city field")
    func placeEqualsCityInvariant() {
        let both = JournalingMoment(
            content: .location(place: "Firenze", city: "Firenze"), date: visitDate, coordinate: nil
        )
        let placeOnly = JournalingMoment(
            content: .location(place: "Firenze", city: nil), date: visitDate, coordinate: nil
        )

        #expect(both.idempotencyID == placeOnly.idempotencyID)
    }

    /// The coordinate is not part of identity: a place's fix wanders by metres
    /// between pulls, and the place text already names the spot. Two moments that
    /// differ only in coordinate (or in whether one is present) are the same
    /// breadcrumb and must share an id.
    @Test("The coordinate does not affect the id")
    func coordinateDoesNotAffectID() throws {
        let text = JournalingMoment.Content.location(place: "Colosseo", city: "Roma")
        let a = try #require(Coordinate(latitude: 41.89021, longitude: 12.49223))
        let b = try #require(Coordinate(latitude: 43.77670, longitude: 11.25940))

        let withA = JournalingMoment(content: text, date: visitDate, coordinate: a)
        let withB = JournalingMoment(content: text, date: visitDate, coordinate: b)
        let without = JournalingMoment(content: text, date: visitDate, coordinate: nil)

        #expect(withA.idempotencyID == withB.idempotencyID)
        #expect(withA.idempotencyID == without.idempotencyID)
    }

    @Test("A different place derives a different id")
    func differentPlace() {
        let a = JournalingMoment(
            content: .location(place: "Colosseo", city: "Roma"), date: visitDate, coordinate: nil
        )
        let b = JournalingMoment(
            content: .location(place: "Foro Romano", city: "Roma"), date: visitDate, coordinate: nil
        )

        #expect(a.idempotencyID != b.idempotencyID)
    }

    /// Same fields but a different kind must stay distinct — a single-place group
    /// and a lone location can render the same text, so the kind tag is what keeps
    /// them apart.
    @Test("The same text under a different kind derives a different id")
    func kindIsPartOfIdentity() {
        let location = JournalingMoment(
            content: .location(place: "Duomo", city: nil), date: visitDate, coordinate: nil
        )
        let group = JournalingMoment(
            content: .locationGroup(city: nil, places: ["Duomo"]), date: visitDate, coordinate: nil
        )

        #expect(location.idempotencyID != group.idempotencyID)
    }

    // MARK: - Date

    @Test("A visit on another day derives a different id")
    func differentDay() {
        let a = JournalingMoment(
            content: .location(place: "Colosseo", city: "Roma"), date: visitDate, coordinate: nil
        )
        let b = JournalingMoment(
            content: .location(place: "Colosseo", city: "Roma"),
            date: visitDate.addingTimeInterval(86_400), coordinate: nil
        )

        #expect(a.idempotencyID != b.idempotencyID)
    }

    /// The date is bucketed to the minute, so a start re-derived a few seconds apart
    /// still dedupes, while visits minutes apart stay distinct.
    @Test("Seconds of drift keep the id; minutes apart change it")
    func minuteBucket() {
        let base = JournalingMoment(
            content: .location(place: "Colosseo", city: "Roma"), date: visitDate, coordinate: nil
        )
        let fiveSeconds = JournalingMoment(
            content: .location(place: "Colosseo", city: "Roma"),
            date: visitDate.addingTimeInterval(5), coordinate: nil
        )
        let twoMinutes = JournalingMoment(
            content: .location(place: "Colosseo", city: "Roma"),
            date: visitDate.addingTimeInterval(120), coordinate: nil
        )

        #expect(base.idempotencyID == fiveSeconds.idempotencyID)
        #expect(base.idempotencyID != twoMinutes.idempotencyID)
    }

    // MARK: - Event poster (the branch nothing else exercises)

    @Test("Equal event posters match; a different title does not")
    func eventPosterIdentity() {
        let wedding = JournalingMoment(
            content: .eventPoster(title: "Marco's wedding", place: "Villa San Michele"),
            date: visitDate, coordinate: nil
        )
        let sameWedding = JournalingMoment(
            content: .eventPoster(title: "marco's wedding", place: "villa san michele"),
            date: visitDate, coordinate: nil
        )
        let otherEvent = JournalingMoment(
            content: .eventPoster(title: "Giulia's recital", place: "Villa San Michele"),
            date: visitDate, coordinate: nil
        )

        #expect(wedding.idempotencyID == sameWedding.idempotencyID)
        #expect(wedding.idempotencyID != otherEvent.idempotencyID)
    }

    // MARK: - Shape

    @Test("The id is a stamped, hash-derived UUID")
    func idIsWellFormed() {
        let id = JournalingMoment(
            content: .location(place: "Colosseo", city: "Roma"), date: visitDate, coordinate: nil
        ).idempotencyID

        #expect(id != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        // Version nibble (byte 6 high nibble) stamped to 8; variant (byte 8 top
        // bits) to 0b10. Deriving twice must be identical, never random.
        #expect(id.uuid.6 >> 4 == 0x8)
        #expect(id.uuid.8 >> 6 == 0b10)
    }
}

/// Ties the derived id to the real dedup door: enqueuing the same moment twice
/// must leave exactly one record. Serialized for the same store-setup reason as
/// ``WatchCaptureReceiverTests``.
@Suite(.serialized)
struct JournalingMomentDedupIntegrationTests {
    private let visitDate = Date(timeIntervalSince1970: 1_700_000_000)

    private final class Fixture {
        let directory: URL
        let container: ModelContainer
        let queue: CaptureQueue

        init() throws {
            directory = URL.temporaryDirectory.appending(path: "JournalingDedupTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            container = try ModelContainer(
                for: CaptureRecord.self,
                configurations: ModelConfiguration(url: directory.appending(path: "captures.store"))
            )
            let appGroup = AppGroupContainer(rootURL: directory)
            try appGroup.prepareDirectories()
            queue = CaptureQueue(container: container, appGroup: appGroup)
        }

        func recordCount() throws -> Int {
            try ModelContext(container).fetch(FetchDescriptor<CaptureRecord>()).count
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    @Test("Re-pulling the same moment enqueues once, then dedupes")
    func rePullDedupes() async throws {
        let fixture = try Fixture()
        let moment = JournalingMoment(
            content: .location(place: "Galleria dell'Accademia", city: "Firenze"),
            date: visitDate, coordinate: nil
        )
        let draft = try #require(moment.noteDraft())

        let first = try await fixture.queue.enqueue(note: draft, id: moment.idempotencyID)
        let second = try await fixture.queue.enqueue(note: draft, id: moment.idempotencyID)

        #expect(first == .inserted)
        #expect(second == .duplicate)
        #expect(try fixture.recordCount() == 1)
    }
}
