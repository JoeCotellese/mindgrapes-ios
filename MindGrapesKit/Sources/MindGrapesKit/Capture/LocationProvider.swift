// ABOUTME: Produces a one-shot location fix under a strict time budget, with non-fatal reverse geocoding.
// ABOUTME: The CoreLocation seams are injected so the budget and geocode logic test off-device (SPEC 9).

import Foundation

/// A location fix attached to a capture (SPEC 9): coordinates, plus an optional
/// human-readable label when reverse geocoding succeeds in time.
public struct LocationFix: Sendable, Equatable {
    public let coordinate: Coordinate
    public let placeLabel: String?

    public init(coordinate: Coordinate, placeLabel: String?) {
        self.coordinate = coordinate
        self.placeLabel = placeLabel
    }
}

/// A single best-effort location fix. May be slow, and returns `nil` when
/// location is unavailable or the user denied it. The CoreLocation-backed
/// implementation is device/simulator only; tests inject a fake.
public protocol OneShotLocating: Sendable {
    func location() async -> Coordinate?
}

/// Turns a coordinate into a place label. Returns `nil` on any failure, which
/// SPEC 9 treats as non-fatal: the fix keeps its coordinate and drops the label.
public protocol ReverseGeocoding: Sendable {
    func placeLabel(for coordinate: Coordinate) async -> String?
}

/// The one-shot location pipeline (SPEC 9).
///
/// Two guarantees, both the reason this type exists rather than a bare
/// `CLLocationManager` call:
///
/// - **Location never delays a capture past the budget.** The coordinate lookup
///   races a timeout; on timeout the fix is `nil` and the capture proceeds
///   without location. Reverse geocoding is bounded the same way, so a hung
///   geocoder cannot stall a capture either — it just drops the label.
/// - **A geocode failure is not a location failure.** A coordinate with no label
///   is still a fix (SPEC 9); only a missing coordinate is no fix.
///
/// The budget bounds each stage independently, so the worst-case wall time is
/// two budgets (a locator that answers just under the deadline, then a geocoder
/// that times out). That is acceptable: the common path answers both promptly,
/// and the guarantee that matters is that neither stage can hang unboundedly.
public struct LocationProvider: Sendable {
    private let locator: any OneShotLocating
    private let geocoder: any ReverseGeocoding
    private let budget: Duration

    /// - Parameters:
    ///   - locator: the one-shot coordinate source (CoreLocation in production).
    ///   - geocoder: the reverse geocoder (CLGeocoder in production).
    ///   - budget: the per-stage time budget. SPEC 9's 3 seconds by default.
    public init(
        locator: any OneShotLocating,
        geocoder: any ReverseGeocoding,
        budget: Duration = .seconds(3)
    ) {
        self.locator = locator
        self.geocoder = geocoder
        self.budget = budget
    }

    /// A fix, or `nil` if no coordinate arrived within the budget (denied,
    /// unavailable, or too slow). A coordinate that arrives keeps its place label
    /// only if the geocode also answers within the budget.
    public func currentFix() async -> LocationFix? {
        guard let coordinate = await withBudget({ await locator.location() }) else {
            return nil
        }
        let label = await withBudget { await geocoder.placeLabel(for: coordinate) }
        return LocationFix(coordinate: coordinate, placeLabel: label)
    }

    /// A coordinate with no reverse geocode attempted at all.
    ///
    /// The wrist's path (SPEC 9, and the decision recorded on #22). `CLGeocoder`
    /// needs network, and a Watch with no phone nearby is exactly a Watch with no
    /// network, so on the case that matters most — a capture made on a run —
    /// geocoding would spend the whole budget to return `nil`. The phone labels the
    /// coordinate when it receives the handoff instead.
    public func currentCoordinate() async -> Coordinate? {
        await withTimeBudget(budget) { await self.locator.location() }
    }

    /// Runs `operation` under this provider's budget. See ``withTimeBudget``.
    private func withBudget<T: Sendable>(_ operation: @escaping @Sendable () async -> T?) async -> T? {
        await withTimeBudget(budget, operation)
    }
}
