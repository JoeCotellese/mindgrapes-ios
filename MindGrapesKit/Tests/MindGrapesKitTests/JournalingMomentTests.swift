// ABOUTME: Proves a Journaling Suggestion maps to the right note text, date, and coordinate.
// ABOUTME: The date coming from the moment and never from "now" is issue #52's whole point.

import Foundation
import Testing

@testable import MindGrapesKit

/// `JournalingMoment` is the boundary value the app adapter fills from an
/// un-simulatable `JournalingSuggestion`, so every mapping decision is tested
/// here rather than against the framework. Mirrors `WatchCapturePayloadTests`.
@Suite
struct JournalingMomentTests {
    /// A fixed past date, deliberately not "now": the assertions below would pass
    /// by accident if the mapping defaulted to `Date()` and the test also used it.
    private let visitDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Location

    @Test("A location with a city reads 'Visited place, city'")
    func locationWithCity() throws {
        let moment = JournalingMoment(
            content: .location(place: "Galleria dell'Accademia", city: "Firenze"),
            date: visitDate,
            coordinate: nil
        )

        let draft = try #require(moment.noteDraft())

        #expect(draft.content == "Visited Galleria dell'Accademia, Firenze")
    }

    @Test("A location with no city drops the comma")
    func locationWithoutCity() throws {
        let moment = JournalingMoment(
            content: .location(place: "Ponte Vecchio", city: nil),
            date: visitDate,
            coordinate: nil
        )

        let draft = try #require(moment.noteDraft())

        #expect(draft.content == "Visited Ponte Vecchio")
    }

    @Test("A blank city is treated as absent")
    func locationBlankCity() throws {
        let moment = JournalingMoment(
            content: .location(place: "Duomo", city: "   "),
            date: visitDate,
            coordinate: nil
        )

        let draft = try #require(moment.noteDraft())

        #expect(draft.content == "Visited Duomo")
    }

    @Test("A location with no place is not a breadcrumb")
    func locationBlankPlace() {
        let moment = JournalingMoment(
            content: .location(place: "  ", city: "Firenze"),
            date: visitDate,
            coordinate: nil
        )

        #expect(moment.noteDraft() == nil)
    }

    // MARK: - Location group

    @Test("A location group with a city lists the places after it")
    func groupWithCity() throws {
        let moment = JournalingMoment(
            content: .locationGroup(
                city: "Firenze",
                places: ["Galleria dell'Accademia", "Ponte Vecchio", "Duomo"]
            ),
            date: visitDate,
            coordinate: nil
        )

        let draft = try #require(moment.noteDraft())

        #expect(draft.content == "Visited Firenze: Galleria dell'Accademia, Ponte Vecchio, Duomo")
    }

    @Test("A location group with no city just lists the places")
    func groupWithoutCity() throws {
        let moment = JournalingMoment(
            content: .locationGroup(city: nil, places: ["Ponte Vecchio", "Duomo"]),
            date: visitDate,
            coordinate: nil
        )

        let draft = try #require(moment.noteDraft())

        #expect(draft.content == "Visited Ponte Vecchio, Duomo")
    }

    @Test("Blank places are dropped from a group")
    func groupDropsBlankPlaces() throws {
        let moment = JournalingMoment(
            content: .locationGroup(city: "Firenze", places: ["Duomo", "  ", "Ponte Vecchio"]),
            date: visitDate,
            coordinate: nil
        )

        let draft = try #require(moment.noteDraft())

        #expect(draft.content == "Visited Firenze: Duomo, Ponte Vecchio")
    }

    @Test("A group with no usable places is not a breadcrumb")
    func groupNoPlaces() {
        let empty = JournalingMoment(
            content: .locationGroup(city: "Firenze", places: []),
            date: visitDate,
            coordinate: nil
        )
        let blankOnly = JournalingMoment(
            content: .locationGroup(city: "Firenze", places: ["   ", ""]),
            date: visitDate,
            coordinate: nil
        )

        #expect(empty.noteDraft() == nil)
        #expect(blankOnly.noteDraft() == nil)
    }

    // MARK: - Event poster

    @Test("An event with a place reads 'Attended title at place'")
    func eventWithPlace() throws {
        let moment = JournalingMoment(
            content: .eventPoster(title: "Marco's wedding", place: "Villa San Michele"),
            date: visitDate,
            coordinate: nil
        )

        let draft = try #require(moment.noteDraft())

        #expect(draft.content == "Attended Marco's wedding at Villa San Michele")
    }

    @Test("An event with no place drops the 'at' clause")
    func eventWithoutPlace() throws {
        let moment = JournalingMoment(
            content: .eventPoster(title: "Marco's wedding", place: nil),
            date: visitDate,
            coordinate: nil
        )

        let draft = try #require(moment.noteDraft())

        #expect(draft.content == "Attended Marco's wedding")
    }

    @Test("An event with a venue but no title keeps the venue")
    func eventBlankTitleKeepsVenue() throws {
        // Poster OCR that caught the venue but missed the title still leaves a
        // usable venue+date breadcrumb; dropping it would lose a tapped moment.
        let moment = JournalingMoment(
            content: .eventPoster(title: "  ", place: "Villa San Michele"),
            date: visitDate,
            coordinate: nil
        )

        let draft = try #require(moment.noteDraft())

        #expect(draft.content == "Visited Villa San Michele")
    }

    @Test("An event with neither title nor venue is not a breadcrumb")
    func eventBothBlank() {
        #expect(
            JournalingMoment(
                content: .eventPoster(title: " ", place: nil), date: visitDate, coordinate: nil
            ).noteDraft() == nil
        )
        #expect(
            JournalingMoment(
                content: .eventPoster(title: "", place: "   "), date: visitDate, coordinate: nil
            ).noteDraft() == nil
        )
    }

    // MARK: - Date and coordinate (the hard requirements)

    /// The single most important assertion in the feature: the note is stamped
    /// with the visit date, never with when the user tapped the picker.
    @Test("occurred_at is the moment's date, never now")
    func occurredAtIsTheVisitDate() throws {
        let moment = JournalingMoment(
            content: .location(place: "Colosseo", city: "Roma"),
            date: visitDate,
            coordinate: nil
        )

        let draft = try #require(moment.noteDraft())

        #expect(draft.occurredAt == visitDate)
    }

    @Test("A coordinate is carried onto the draft when present")
    func coordinateCarried() throws {
        let coordinate = try #require(Coordinate(latitude: 43.7767, longitude: 11.2594))
        let moment = JournalingMoment(
            content: .location(place: "Galleria dell'Accademia", city: "Firenze"),
            date: visitDate,
            coordinate: coordinate
        )

        let draft = try #require(moment.noteDraft())

        #expect(draft.coordinate == coordinate)
    }

    @Test("No coordinate yields a draft with no location, not a bogus one")
    func coordinateAbsent() throws {
        let moment = JournalingMoment(
            content: .location(place: "Galleria dell'Accademia", city: "Firenze"),
            date: visitDate,
            coordinate: nil
        )

        let draft = try #require(moment.noteDraft())

        #expect(draft.coordinate == nil)
    }

    // MARK: - Trimming, redundancy, and Unicode

    @Test("Padded place and city names are trimmed in the text")
    func trimsPaddedNames() throws {
        let single = JournalingMoment(
            content: .location(place: "  Duomo  ", city: "  Firenze  "),
            date: visitDate, coordinate: nil
        )
        let group = JournalingMoment(
            content: .locationGroup(city: "  Roma  ", places: ["  Colosseo  ", " Foro "]),
            date: visitDate, coordinate: nil
        )

        #expect(try #require(single.noteDraft()).content == "Visited Duomo, Firenze")
        #expect(try #require(group.noteDraft()).content == "Visited Roma: Colosseo, Foro")
    }

    @Test("A place already qualified with its city does not double it")
    func placeAlreadyNamesCity() throws {
        let qualified = JournalingMoment(
            content: .location(place: "Galleria dell'Accademia, Firenze", city: "Firenze"),
            date: visitDate, coordinate: nil
        )
        let placeIsCity = JournalingMoment(
            content: .location(place: "Firenze", city: "firenze"),
            date: visitDate, coordinate: nil
        )

        #expect(try #require(qualified.noteDraft()).content == "Visited Galleria dell'Accademia, Firenze")
        #expect(try #require(placeIsCity.noteDraft()).content == "Visited Firenze")
    }

    @Test("A group with a blank city just lists the places")
    func groupBlankCity() throws {
        let moment = JournalingMoment(
            content: .locationGroup(city: "   ", places: ["Duomo", "Ponte Vecchio"]),
            date: visitDate, coordinate: nil
        )

        #expect(try #require(moment.noteDraft()).content == "Visited Duomo, Ponte Vecchio")
    }

    @Test("Duplicate places in a group collapse, keeping reading order")
    func groupDedupesPlaces() throws {
        let moment = JournalingMoment(
            content: .locationGroup(city: "Roma", places: ["Colosseo", "colosseo", "Foro", "Colosseo"]),
            date: visitDate, coordinate: nil
        )

        #expect(try #require(moment.noteDraft()).content == "Visited Roma: Colosseo, Foro")
    }

    @Test("Accents and typographic apostrophes are preserved verbatim")
    func preservesUnicode() throws {
        // iOS commonly returns a curly apostrophe (U+2019) and accented letters;
        // the mapping interpolates them unchanged rather than normalizing.
        let moment = JournalingMoment(
            content: .location(place: "Caffè dell\u{2019}Università", city: "Perugia"),
            date: visitDate, coordinate: nil
        )

        #expect(try #require(moment.noteDraft()).content == "Visited Caffè dell\u{2019}Università, Perugia")
    }

    // MARK: - Date passthrough across every kind

    @Test("occurred_at is the visit date for the group and event kinds too")
    func occurredAtAcrossKinds() throws {
        let group = JournalingMoment(
            content: .locationGroup(city: "Roma", places: ["Colosseo"]),
            date: visitDate, coordinate: nil
        )
        let event = JournalingMoment(
            content: .eventPoster(title: "Marco's wedding", place: nil),
            date: visitDate, coordinate: nil
        )

        #expect(try #require(group.noteDraft()).occurredAt == visitDate)
        #expect(try #require(event.noteDraft()).occurredAt == visitDate)
    }

    // MARK: - Equality (the contract Phase 3's dedup leans on)

    @Test("Two moments are equal exactly when content, date, and coordinate match")
    func equatableContract() throws {
        let coordinate = try #require(Coordinate(latitude: 41.8902, longitude: 12.4922))
        let base = JournalingMoment(
            content: .location(place: "Colosseo", city: "Roma"), date: visitDate, coordinate: coordinate
        )

        #expect(base == JournalingMoment(
            content: .location(place: "Colosseo", city: "Roma"), date: visitDate, coordinate: coordinate
        ))
        #expect(base != JournalingMoment(
            content: .location(place: "Colosseo", city: "Roma"),
            date: Date(timeIntervalSince1970: 1), coordinate: coordinate
        ))
        #expect(base != JournalingMoment(
            content: .location(place: "Foro", city: "Roma"), date: visitDate, coordinate: coordinate
        ))
    }
}
