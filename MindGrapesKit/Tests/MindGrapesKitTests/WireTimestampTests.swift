// ABOUTME: Pins the exact `occurred_at` string both capture doors receive.
// ABOUTME: SPEC 6.3 feeds it to Postgres as ::timestamptz, so the shape is a contract, not a detail.

import Foundation
import Testing

@testable import MindGrapesKit

@Suite struct WireTimestampTests {
    /// 2025-07-23T16:03:11Z, the instant SPEC 6.3's example is written against.
    private let instant = Date(timeIntervalSince1970: 1_753_286_591)

    @Test func formatsWithAnExplicitNumericOffset() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        #expect(WireTimestamp.string(from: instant, in: zone) == "2025-07-23T12:03:11-04:00")
    }

    @Test func utcGetsAZeroOffsetRatherThanZ() throws {
        // SPEC 6.3 asks for "ISO 8601 with a UTC offset". `Z` is legal ISO 8601
        // but it is a different spelling, and nothing has confirmed the server's
        // parser treats the two identically, so the client only ever emits the
        // numeric form.
        let zone = try #require(TimeZone(identifier: "UTC"))
        #expect(WireTimestamp.string(from: instant, in: zone) == "2025-07-23T16:03:11+00:00")
    }

    @Test func formatsOffsetsThatAreNotWholeHours() throws {
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        #expect(WireTimestamp.string(from: instant, in: kolkata) == "2025-07-23T21:33:11+05:30")

        let chatham = try #require(TimeZone(identifier: "Pacific/Chatham"))
        #expect(WireTimestamp.string(from: instant, in: chatham) == "2025-07-24T04:48:11+12:45")
    }

    @Test func neverEmitsFractionalSeconds() throws {
        // A sub-second component would have to round somewhere; truncating to
        // the second keeps the string reproducible for a given record.
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let fractional = Date(timeIntervalSince1970: 1_753_286_591.987)
        #expect(WireTimestamp.string(from: fractional, in: zone) == "2025-07-23T12:03:11-04:00")
    }

    @Test func padsEveryComponentToItsFixedWidth() throws {
        let zone = try #require(TimeZone(identifier: "UTC"))
        // 2001-02-03T04:05:06Z: every field needs a leading zero.
        let padded = Date(timeIntervalSince1970: 981_173_106)
        #expect(WireTimestamp.string(from: padded, in: zone) == "2001-02-03T04:05:06+00:00")
    }

    @Test func theSameInstantFormatsIdenticallyEveryTime() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let first = WireTimestamp.string(from: instant, in: zone)
        #expect(first == WireTimestamp.string(from: instant, in: zone))
    }
}
