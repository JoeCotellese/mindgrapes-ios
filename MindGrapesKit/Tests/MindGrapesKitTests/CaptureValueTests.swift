// ABOUTME: Covers the value types a capture is built from: Person, Coordinate, drafts.
// ABOUTME: Asserts the invariants SPEC 6.3 relies on so the wire encoder cannot emit junk.

import Foundation
import Testing

@testable import MindGrapesKit

// MARK: - Person

@Test func personKeepsAUsableName() throws {
    let person = try #require(Person(name: "Lung"))
    #expect(person.name == "Lung")
    #expect(person.relationship == nil)
}

@Test func personTrimsSurroundingWhitespace() throws {
    let person = try #require(Person(name: "  Anna \n", relationship: " friend "))
    #expect(person.name == "Anna")
    #expect(person.relationship == "friend")
}

@Test func personRejectsAnEmptyName() {
    // The server silently skips a participant object with no usable name
    // (SPEC 6.3), so a nameless Person must be unrepresentable rather than
    // silently dropped downstream.
    #expect(Person(name: "") == nil)
    #expect(Person(name: "   \t ") == nil)
}

@Test func personDropsAnEmptyRelationship() throws {
    let person = try #require(Person(name: "Marco", relationship: "  "))
    #expect(person.relationship == nil)
}

// MARK: - Coordinate

@Test func coordinateAcceptsAValidPair() throws {
    let coordinate = try #require(Coordinate(latitude: 39.9526, longitude: -75.1652))
    #expect(coordinate.latitude == 39.9526)
    #expect(coordinate.longitude == -75.1652)
}

@Test func coordinateRejectsOutOfRangeValues() {
    #expect(Coordinate(latitude: 90.1, longitude: 0) == nil)
    #expect(Coordinate(latitude: -90.1, longitude: 0) == nil)
    #expect(Coordinate(latitude: 0, longitude: 180.1) == nil)
    #expect(Coordinate(latitude: 0, longitude: -180.1) == nil)
}

@Test func coordinateRejectsNonFiniteValues() {
    #expect(Coordinate(latitude: .nan, longitude: 0) == nil)
    #expect(Coordinate(latitude: 0, longitude: .infinity) == nil)
}

@Test func coordinateAcceptsTheRangeBoundaries() {
    #expect(Coordinate(latitude: 90, longitude: 180) != nil)
    #expect(Coordinate(latitude: -90, longitude: -180) != nil)
}

// MARK: - NoteDraft

@Test func noteDraftTrimsContent() throws {
    let draft = try #require(NoteDraft(content: "  Met Lung at LIFT Labs.  "))
    #expect(draft.content == "Met Lung at LIFT Labs.")
}

@Test func noteDraftRejectsEmptyContent() {
    // SPEC 7.1 step 1: never enqueue an empty capture.
    #expect(NoteDraft(content: "") == nil)
    #expect(NoteDraft(content: " \n\t ") == nil)
}

@Test func noteDraftDefaultsAreEmptyRatherThanAbsent() throws {
    let draft = try #require(NoteDraft(content: "hello"))
    #expect(draft.coordinate == nil)
    #expect(draft.placeLabel == nil)
    #expect(draft.people.isEmpty)
    #expect(draft.labels.isEmpty)
}

@Test func noteDraftCarriesItsMetadata() throws {
    let when = Date(timeIntervalSince1970: 1_753_286_591)
    let draft = try #require(
        NoteDraft(
            content: "Met Lung at the LIFT Labs demo.",
            occurredAt: when,
            coordinate: Coordinate(latitude: 39.9526, longitude: -75.1652),
            placeLabel: "Comcast Center, Philadelphia",
            people: [Person(name: "Lung")].compactMap { $0 },
            labels: ["lift-labs"]
        )
    )
    #expect(draft.occurredAt == when)
    #expect(draft.coordinate?.latitude == 39.9526)
    #expect(draft.placeLabel == "Comcast Center, Philadelphia")
    #expect(draft.people.map(\.name) == ["Lung"])
    #expect(draft.labels == ["lift-labs"])
}

// MARK: - PhotoDraft

@Test func photoDraftRequiresASpoolFilenameAndDescription() {
    // SPEC 11: this client always supplies a description, which is what keeps
    // the server's OpenRouter vision fallback dead code.
    #expect(PhotoDraft(imageFilename: "", description: "A dog food label.") == nil)
    #expect(PhotoDraft(imageFilename: "a.jpg", description: "   ") == nil)
}

@Test func photoDraftTrimsItsText() throws {
    let draft = try #require(
        PhotoDraft(
            imageFilename: " a.jpg ",
            description: "  A dog food label.  ",
            ocrText: "  Ingredients: chicken  ",
            event: "  Shopping  "
        )
    )
    #expect(draft.imageFilename == "a.jpg")
    #expect(draft.description == "A dog food label.")
    #expect(draft.ocrText == "Ingredients: chicken")
    #expect(draft.event == "Shopping")
}

@Test func photoDraftDropsEmptyOptionalText() throws {
    let draft = try #require(
        PhotoDraft(imageFilename: "a.jpg", description: "A label.", ocrText: " ", event: "")
    )
    #expect(draft.ocrText == nil)
    #expect(draft.event == nil)
}

// MARK: - ServerConfig

@Test func serverConfigCarriesItsBaseURL() throws {
    let url = try #require(URL(string: "https://brain.example.ts.net"))
    #expect(ServerConfig(baseURL: url).baseURL == url)
}

// MARK: - Sendability

@Test func captureValueTypesAreSendable() {
    // A compile-time assertion: these only build if the conformance exists.
    func requireSendable<T: Sendable>(_: T.Type) {}
    requireSendable(Person.self)
    requireSendable(Coordinate.self)
    requireSendable(NoteDraft.self)
    requireSendable(PhotoDraft.self)
    requireSendable(ServerConfig.self)
    requireSendable(CaptureKind.self)
    requireSendable(CaptureState.self)
}
