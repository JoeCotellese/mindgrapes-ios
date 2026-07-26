// ABOUTME: Proves a location fix goes stale rather than being stamped on a capture made elsewhere.
// ABOUTME: A wrong location is worse than none, because a missing one is already normal (SPEC 9).

import Foundation
import Testing

@testable import MindGrapesKit

@Suite
struct TimedCoordinateTests {
    private let takenAt = Date(timeIntervalSince1970: 1_000_000)
    private let somewhere = Coordinate(latitude: 40, longitude: -75)!

    @Test("A fix taken just now is used")
    func freshFixIsUsed() {
        let fix = TimedCoordinate(coordinate: somewhere, takenAt: takenAt)

        #expect(fix.coordinate(asOf: takenAt) == somewhere)
    }

    @Test("A fix inside the freshness window is used")
    func fixInsideTheWindowIsUsed() {
        let fix = TimedCoordinate(coordinate: somewhere, takenAt: takenAt)
        let later = takenAt.addingTimeInterval(TimedCoordinate.freshness - 1)

        #expect(fix.coordinate(asOf: later) == somewhere)
    }

    @Test("A fix exactly at the boundary is still used")
    func boundaryIsInclusive() {
        let fix = TimedCoordinate(coordinate: somewhere, takenAt: takenAt)
        let atTheEdge = takenAt.addingTimeInterval(TimedCoordinate.freshness)

        #expect(fix.coordinate(asOf: atTheEdge) == somewhere)
    }

    /// The bug this exists for. Nothing clears the pending fix when the dictation
    /// sheet is dismissed without submitting, so without an expiry a coordinate
    /// taken at one place gets stamped on a capture made at another.
    @Test("A fix past the freshness window is dropped")
    func staleFixIsDropped() {
        let fix = TimedCoordinate(coordinate: somewhere, takenAt: takenAt)
        let muchLater = takenAt.addingTimeInterval(TimedCoordinate.freshness + 1)

        #expect(fix.coordinate(asOf: muchLater) == nil)
    }

    @Test("An hour-old fix is nowhere near fresh")
    func veryOldFixIsDropped() {
        let fix = TimedCoordinate(coordinate: somewhere, takenAt: takenAt)

        #expect(fix.coordinate(asOf: takenAt.addingTimeInterval(3600)) == nil)
    }

    /// Clock adjustment, not staleness. Throwing away a good fix over it would be
    /// the worse trade.
    @Test("A fix stamped in the future is treated as fresh")
    func futureFixIsKept() {
        let fix = TimedCoordinate(coordinate: somewhere, takenAt: takenAt)
        let earlier = takenAt.addingTimeInterval(-30)

        #expect(fix.coordinate(asOf: earlier) == somewhere)
    }
}
