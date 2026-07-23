// ABOUTME: Pins that decoding enforces the same invariants the failable initializers do.
// ABOUTME: Matters because SwiftData rehydrates `people` through `init(from:)`, not through them.

import Foundation
import Testing

@testable import MindGrapesKit

/// A decoder that can read the non-finite doubles plain JSON cannot spell.
private func nonFiniteAwareDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
        positiveInfinity: "inf",
        negativeInfinity: "-inf",
        nan: "nan"
    )
    return decoder
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try nonFiniteAwareDecoder().decode(type, from: Data(json.utf8))
}

// MARK: - Person

@Test func decodingAPersonWithNoUsableNameThrows() {
    // The failable initializer is not the only door into this type: SwiftData
    // persists `people` as a Codable composite attribute, so every read from
    // the store runs `init(from:)`. Without this check the invariant holds at
    // construction and evaporates on the next launch.
    #expect(throws: DecodingError.self) {
        try decode(Person.self, #"{"name":""}"#)
    }
    #expect(throws: DecodingError.self) {
        try decode(Person.self, #"{"name":"   \t "}"#)
    }
}

@Test func decodingAPersonTrimsLikeTheInitializerDoes() throws {
    let person = try decode(Person.self, #"{"name":"  Anna \n","relationship":" friend "}"#)
    let constructed = try #require(Person(name: "  Anna \n", relationship: " friend "))
    // Same input, same value, whichever door it came through.
    #expect(person == constructed)
    #expect(person.name == "Anna")
    #expect(person.relationship == "friend")
}

@Test func decodingAPersonDropsAnEmptyRelationship() throws {
    #expect(try decode(Person.self, #"{"name":"Marco","relationship":"  "}"#).relationship == nil)
    #expect(try decode(Person.self, #"{"name":"Marco"}"#).relationship == nil)
}

@Test func personRoundTripsThroughJSON() throws {
    for original in [Person(name: "Lung", relationship: "colleague"), Person(name: "Anna")] {
        let original = try #require(original)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Person.self, from: data) == original)
    }
}

// MARK: - Coordinate

@Test func decodingAnOutOfRangeCoordinateThrows() {
    #expect(throws: DecodingError.self) {
        try decode(Coordinate.self, #"{"latitude":999,"longitude":999}"#)
    }
    #expect(throws: DecodingError.self) {
        try decode(Coordinate.self, #"{"latitude":0,"longitude":-180.5}"#)
    }
}

@Test func decodingANonFiniteCoordinateThrows() {
    #expect(throws: DecodingError.self) {
        try decode(Coordinate.self, #"{"latitude":"nan","longitude":0}"#)
    }
    #expect(throws: DecodingError.self) {
        try decode(Coordinate.self, #"{"latitude":0,"longitude":"inf"}"#)
    }
}

@Test func coordinateRoundTripsThroughJSON() throws {
    let original = try #require(Coordinate(latitude: 39.9526, longitude: -75.1652))
    let data = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(Coordinate.self, from: data) == original)
}

@Test func coordinateDecodesTheRangeBoundaries() throws {
    #expect(try decode(Coordinate.self, #"{"latitude":90,"longitude":180}"#).latitude == 90)
    #expect(try decode(Coordinate.self, #"{"latitude":-90,"longitude":-180}"#).longitude == -180)
}
