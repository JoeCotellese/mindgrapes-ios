// ABOUTME: A validated latitude/longitude pair, the only way to carry a location.
// ABOUTME: Pairing them in one value makes the wire's both-or-neither rule unbreakable.

import Foundation

/// A location fix in decimal degrees.
///
/// SPEC 6.3: `lat` and `lng` are both-or-neither on the capture doors, and each
/// must parse as a finite float inside its range or the server answers `400`.
/// Keeping the pair in a single optional value means a half-set location cannot
/// be constructed, so the encoder has no failure mode to guard against.
public struct Coordinate: Sendable, Hashable, Codable {
    public let latitude: Double
    public let longitude: Double

    /// Returns `nil` unless both values are finite and in range.
    public init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite else { return nil }
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }
}
