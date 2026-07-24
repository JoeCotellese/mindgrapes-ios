// ABOUTME: Proves LocationProvider enforces its fix budget and treats reverse geocoding as non-fatal.
// ABOUTME: All timing is driven by injected fakes with tiny budgets, so the suite stays fast and deterministic.

import Foundation
import Testing

@testable import MindGrapesKit

@Suite struct LocationProviderTests {
    private let here = Coordinate(latitude: 39.95, longitude: -75.16)!

    private struct StubLocator: OneShotLocating {
        let result: Coordinate?
        var delay: Duration = .zero
        func location() async -> Coordinate? {
            if delay > .zero { try? await Task.sleep(for: delay) }
            return result
        }
    }

    private struct StubGeocoder: ReverseGeocoding {
        let label: String?
        var delay: Duration = .zero
        func placeLabel(for coordinate: Coordinate) async -> String? {
            if delay > .zero { try? await Task.sleep(for: delay) }
            return label
        }
    }

    private func provider(
        _ locator: StubLocator,
        _ geocoder: StubGeocoder,
        budget: Duration = .seconds(3)
    ) -> LocationProvider {
        LocationProvider(locator: locator, geocoder: geocoder, budget: budget)
    }

    @Test func aPromptFixCarriesItsReverseGeocodedLabel() async {
        let fix = await provider(StubLocator(result: here), StubGeocoder(label: "Philadelphia")).currentFix()
        #expect(fix?.coordinate == here)
        #expect(fix?.placeLabel == "Philadelphia")
    }

    @Test func aFailedGeocodeStillYieldsTheCoordinate() async {
        // SPEC 9: geocode failure yields coordinates without a label, not no fix.
        let fix = await provider(StubLocator(result: here), StubGeocoder(label: nil)).currentFix()
        #expect(fix?.coordinate == here)
        #expect(fix?.placeLabel == nil)
    }

    @Test func aDeniedOrUnavailableLocatorYieldsNoFix() async {
        let fix = await provider(StubLocator(result: nil), StubGeocoder(label: "unused")).currentFix()
        #expect(fix == nil)
    }

    @Test func aLocatorSlowerThanTheBudgetTimesOutToNoFix() async {
        // The locator would take 10s; the budget is 20ms, so capture proceeds
        // without location rather than waiting.
        let fix = await provider(
            StubLocator(result: here, delay: .seconds(10)),
            StubGeocoder(label: "never"),
            budget: .milliseconds(20)
        ).currentFix()
        #expect(fix == nil)
    }

    @Test func aSlowGeocodeStillReturnsTheCoordinateWithoutBlocking() async {
        // Coordinate is prompt, but the label lookup hangs; the fix returns with
        // the coordinate and no label instead of stalling the capture.
        let fix = await provider(
            StubLocator(result: here),
            StubGeocoder(label: "never", delay: .seconds(10)),
            budget: .milliseconds(20)
        ).currentFix()
        #expect(fix?.coordinate == here)
        #expect(fix?.placeLabel == nil)
    }
}
