// ABOUTME: The CoreLocation-backed OneShotLocating and CLGeocoder-backed ReverseGeocoding used on device.
// ABOUTME: Untested by the loop suite (needs a device/simulator); LocationProvider holds the tested logic.

// The two devices that capture, and not the macOS host. Scoping the file here
// keeps the CoreLocation APIs that are deprecated on macOS (CLGeocoder) out of the
// `swift test` build, so the loop stays clean.
//
// watchOS joined for SPEC 9's rule that a watch capture carries the fix taken on
// the wrist: a capture made on a run should record where the runner was, not where
// the phone was when it caught up (#22).
#if os(iOS) || os(watchOS)
import CoreLocation
import Foundation

/// A convenience `LocationProvider` wired to the real CoreLocation seams.
///
/// SPEC 9: When-In-Use only, `kCLLocationAccuracyHundredMeters`, a one-shot fix,
/// reverse geocoding that is non-fatal on failure. The budget and geocode logic
/// live in ``LocationProvider``; this only supplies its two dependencies.
extension LocationProvider {
    public static func system(budget: Duration = .seconds(3)) -> LocationProvider {
        LocationProvider(locator: SystemOneShotLocator(), geocoder: systemGeocoder, budget: budget)
    }

    /// The wrist gets no geocoder at all, not even a compiled-in one.
    ///
    /// `CLGeocoder` needs network and a Watch with no phone nearby has none, so
    /// ``LocationProvider/currentCoordinate()`` is the only path the wrist uses and
    /// the label is made on the phone (#22). Excluding it here rather than merely
    /// not calling it keeps `CLGeocoder`'s watchOS deprecation warnings out of the
    /// build, and keeps a network-dependent API out of a binary that has no network.
    private static var systemGeocoder: any ReverseGeocoding {
        #if os(iOS)
        SystemReverseGeocoder()
        #else
        NoReverseGeocoding()
        #endif
    }
}

/// The current When-In-Use authorization, read without starting a request.
///
/// SPEC 9: a denied permission turns the location toggle off with an explanation
/// and no nagging. The UI reads this after a capture came back with no fix to
/// tell "denied" (flip the toggle off) from "just slow this time" (leave it on).
@MainActor
public enum LocationPermission {
    public enum Status: Sendable { case notDetermined, granted, denied }

    public static var status: Status {
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    /// Shows the system prompt and resolves once the user answers.
    ///
    /// Onboarding (#20) asks here, with the pitch, rather than letting the first
    /// capture ambush the user. Awaiting the answer is what makes the location
    /// toggle honest: firing the request and reading ``status`` on the next line
    /// would read `notDetermined`, because the user has not tapped anything yet.
    ///
    /// An already-answered permission returns immediately: iOS shows the prompt
    /// once per install, so a second request is a silent no-op that would
    /// otherwise hang.
    @MainActor
    public static func request() async -> Status {
        guard status == .notDetermined else { return status }
        return await AuthorizationRequest().run()
    }
}

/// One `requestWhenInUseAuthorization()`, bridged to `async`.
///
/// Same shape as ``OneShotLocationRequest``: the request holds itself alive
/// across the callback because `CLLocationManager` holds its delegate weakly,
/// and `finish` is single-resume so a repeated callback cannot double-resume.
@MainActor
private final class AuthorizationRequest: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<LocationPermission.Status, Never>?
    private var selfHold: AuthorizationRequest?

    func run() async -> LocationPermission.Status {
        // Cancellation-aware for the same reason ``OneShotLocationRequest`` is: a
        // `CheckedContinuation` is not on its own, and the prompt can go
        // unanswered indefinitely (the user backgrounds the app while the alert
        // is up). Without this the caller's task would hang forever and this
        // object, its manager, and its `selfHold` would leak for the life of the
        // process. On cancel we resolve with whatever iOS currently reports,
        // which for an unanswered prompt is `notDetermined`: the honest answer.
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.selfHold = self
                manager.delegate = self
                manager.requestWhenInUseAuthorization()
            }
        } onCancel: {
            Task { @MainActor in self.finish(with: LocationPermission.status) }
        }
    }

    private func finish(with status: LocationPermission.Status) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: status)
        selfHold = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            // The delegate fires once on assignment with the pre-answer status;
            // only a decision resolves the await.
            guard self.manager.authorizationStatus != .notDetermined else { return }
            self.finish(with: LocationPermission.status)
        }
    }
}

/// One `CLLocationManager.requestLocation()`, bridged to `async`.
///
/// A fresh manager per request keeps the whole CoreLocation object graph inside
/// one MainActor-isolated call, so nothing non-`Sendable` escapes. A denied or
/// restricted authorization resolves to `nil` (no fix) rather than hanging.
public struct SystemOneShotLocator: OneShotLocating {
    public init() {}

    public func location() async -> Coordinate? {
        await OneShotLocationRequest().run()
    }
}

@MainActor
private final class OneShotLocationRequest: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Coordinate?, Never>?
    /// The request keeps itself alive across the async callbacks; the manager
    /// holds its delegate weakly.
    private var selfHold: OneShotLocationRequest?

    func run() async -> Coordinate? {
        // The cancellation handler is what makes ``LocationProvider``'s budget
        // real. A CheckedContinuation is not cancellation-aware on its own: when
        // the budget's timeout cancels this task, nothing resumes the
        // continuation, so without this handler the caller would block until
        // CoreLocation itself called back — up to its own ~10s timeout, or forever
        // if a notDetermined permission prompt is never answered. On cancel we
        // stop the pending request and finish with no fix, promptly.
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.selfHold = self
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                proceed(for: manager.authorizationStatus)
            }
        } onCancel: {
            // Hops to the actor the request lives on; `finish` is single-resume,
            // so a real callback racing this cancel resolves to whichever lands first.
            Task { @MainActor in
                self.manager.stopUpdatingLocation()
                self.finish(with: nil)
            }
        }
    }

    private func proceed(for status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            // Denied or restricted: no fix. SPEC 9 turns the toggle off elsewhere;
            // here the contract is simply "no coordinate".
            finish(with: nil)
        }
    }

    /// Resumes exactly once. Any later delegate callback finds `continuation` nil
    /// and is ignored, so a `didFailWithError` after a `didUpdateLocations` (or a
    /// callback arriving after the caller's budget cancelled us) cannot double-resume.
    private func finish(with coordinate: Coordinate?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: coordinate)
        selfHold = nil
    }

    // The delegate methods ignore their `manager` parameter and read the
    // instance's own `self.manager` on the MainActor: the parameter is the same
    // object, but hopping the non-Sendable parameter across the isolation
    // boundary is what Swift 6 rejects.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            // Only act once the user has answered; notDetermined fires first with
            // no decision yet.
            let status = self.manager.authorizationStatus
            guard status != .notDetermined else { return }
            self.proceed(for: status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinates = locations.last?.coordinate
        MainActor.assumeIsolated {
            self.finish(with: coordinates.flatMap {
                Coordinate(latitude: $0.latitude, longitude: $0.longitude)
            })
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated { self.finish(with: nil) }
    }
}

#if os(iOS)
/// `CLGeocoder` reverse geocoding, failing soft to `nil`.
public struct SystemReverseGeocoder: ReverseGeocoding {
    public init() {}

    public func placeLabel(for coordinate: Coordinate) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // Same budget contract as the locator: a cancellation handler cancels the
        // in-flight geocode so LocationProvider's timeout actually frees the
        // caller, instead of blocking on CLGeocoder's own network timeout.
        let box = GeocoderBox()
        let placemark = await withTaskCancellationHandler {
            await box.firstPlacemark(for: location)
        } onCancel: {
            box.cancel()
        }
        guard let placemark else { return nil }
        // Prefer a named place, then the locality; a bare admin area is better
        // than nothing but rarely what a human would call the spot.
        return placemark.name?.nonBlank
            ?? placemark.locality?.nonBlank
            ?? placemark.administrativeArea?.nonBlank
    }
}

/// Holds the `CLGeocoder` so its non-`Sendable` self does not have to cross into
/// the `@Sendable` cancellation closure directly.
///
/// ponytail: `CLGeocoder` is deprecated on iOS 26 in favour of MapKit's
/// `MKReverseGeocodingRequest`, but it still works and the label is a best-effort
/// nicety. Swap to MapKit when the reverse-geocode moves anywhere load-bearing.
///
/// `@unchecked Sendable`: the only method reachable off the calling task is
/// `cancel()`, and `CLGeocoder.cancelGeocode()` is a cancel signal safe to send
/// from another thread; the geocode call itself runs on one task.
private final class GeocoderBox: @unchecked Sendable {
    private let geocoder = CLGeocoder()

    func firstPlacemark(for location: CLLocation) async -> CLPlacemark? {
        try? await geocoder.reverseGeocodeLocation(location).first
    }

    func cancel() {
        geocoder.cancelGeocode()
    }
}
#endif
#endif
