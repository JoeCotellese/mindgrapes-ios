// ABOUTME: Turns a user-picked JournalingSuggestion into a JournalingMoment for the Kit to map.
// ABOUTME: The only place that touches Apple's framework; it reads only place/event text, never media.

// JournalingSuggestions ships in the device SDK only, not the Simulator's, so the
// whole adapter compiles out on Simulator. Its one caller in CaptureView is under
// the same guard, so nothing references it there.
#if canImport(JournalingSuggestions)
import CoreLocation
import JournalingSuggestions
import MindGrapesKit

/// Carries a picked suggestion across one isolation hop, by assertion.
///
/// `JournalingSuggestion` is not `Sendable` and the picker hands it back on the
/// main actor, but `content(forType:)` runs off the main actor — the two cannot
/// meet under strict concurrency without vouching for safety. The crossing is
/// sound here: the picker calls its completion once and does not touch the
/// suggestion again, and this box is read only to extract text, so no two actors
/// ever see it at once. Deliberately the single `@unchecked Sendable` in the
/// feature, and confined to this framework-interop boundary.
struct SendableSuggestion: @unchecked Sendable {
    let suggestion: JournalingSuggestion
}

/// Reads a selected suggestion into a ``JournalingMoment``, or `nil` when it
/// carries nothing we breadcrumb (#52).
///
/// This is the whole of the device-only surface: it asks the suggestion only for
/// the location and event content types, so a photo, workout, or state-of-mind
/// suggestion yields no readable bytes and never leaves the device. Everything it
/// returns is a plain value type the Kit's tested mapping and idempotency logic
/// take from here.
///
/// A missing date means no breadcrumb: "when did we…" cannot be answered without
/// one, so a suggestion with no `date` is skipped rather than stamped with now.
///
/// Takes the suggestion boxed (see ``SendableSuggestion``) so the picker's
/// main-actor completion can hand it to this off-actor reader. The value returned,
/// a ``JournalingMoment``, is `Sendable` and crosses back out freely.
func journalingMoment(from boxed: SendableSuggestion) async -> JournalingMoment? {
    let suggestion = boxed.suggestion
    guard let date = suggestion.date?.start else { return nil }

    // A multi-place outing. One usable place reads better as a single location.
    let groups = await suggestion.content(forType: JournalingSuggestion.LocationGroup.self)
    if let group = groups.first, !group.locations.isEmpty {
        if group.locations.count == 1, let only = group.locations.first {
            return JournalingMoment(
                content: .location(place: only.place ?? "", city: only.city),
                date: date,
                coordinate: coordinate(from: only.location)
            )
        }
        return JournalingMoment(
            content: .locationGroup(
                city: group.locations.first?.city,
                places: group.locations.compactMap(\.place)
            ),
            date: date,
            coordinate: coordinate(from: group.locations.first?.location)
        )
    }

    // A single visited place.
    let locations = await suggestion.content(forType: JournalingSuggestion.Location.self)
    if let location = locations.first {
        return JournalingMoment(
            content: .location(place: location.place ?? "", city: location.city),
            date: date,
            coordinate: coordinate(from: location.location)
        )
    }

    // An event poster. The title is an AttributedString; take its plain text.
    let posters = await suggestion.content(forType: JournalingSuggestion.EventPoster.self)
    if let poster = posters.first {
        return JournalingMoment(
            content: .eventPoster(title: String(poster.title.characters), place: poster.placeName),
            date: date,
            coordinate: nil
        )
    }

    return nil
}

/// A validated `Coordinate` from a fix, or `nil` — both when there is no fix and
/// when the fix is out of range (`Coordinate` is both-or-neither by construction).
private func coordinate(from location: CLLocation?) -> Coordinate? {
    location.flatMap { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
}
#endif
