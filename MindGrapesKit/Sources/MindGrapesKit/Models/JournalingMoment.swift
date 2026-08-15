// ABOUTME: One selected Journaling Suggestion, reduced to the text and metadata a note needs.
// ABOUTME: The app fills it from an un-simulatable JournalingSuggestion; all mapping logic lives here.

import Foundation

/// A moment the user picked from Apple's Journaling Suggestions, on its way to
/// becoming a durable dated text breadcrumb (issue #52).
///
/// This is the boundary value that keeps the framework out of the testable core,
/// the same move ``WatchCapturePayload`` makes for `WCSession`. `JournalingSuggestion`
/// has no public initializer and does not exist on the Simulator or in `swift
/// test`, so the app target's thin adapter reads it and fills one of these, and
/// every decision — the text templates, the skip rules, the date, the coordinate
/// — lives here where a test can reach it without the picker.
///
/// **`date` is required and has no default.** It is the visit or event date, and
/// stamping the note with it rather than with when the user tapped the picker is
/// the entire point of the feature: "when did we see the David statue" has to
/// answer with the day of the visit. ``NoteDraft`` defaults `occurredAt` to
/// `Date()` for typed captures; this type must not, so the compiler refuses a
/// moment that forgot to carry its date.
public struct JournalingMoment: Sendable, Equatable {
    /// The three suggestion kinds we ingest, each carrying only its own text.
    ///
    /// Media, photo, workout, and state-of-mind suggestions are deliberately
    /// absent: they are never requested from the picker, so their bytes are never
    /// read (#52 keeps images off the server entirely). Reflection prompts are out
    /// of v1 because a prompt with no place and no event date is not a breadcrumb.
    public enum Content: Sendable, Equatable {
        /// A single visited place, with the city when the suggestion knew it.
        case location(place: String, city: String?)
        /// Several places from one outing, grouped under a city when known.
        case locationGroup(city: String?, places: [String])
        /// An event poster: the event's title, and its venue when named.
        case eventPoster(title: String, place: String?)
    }

    public let content: Content
    /// The visit or event date, stamped onto the note as `occurred_at`.
    ///
    /// An instant, not a range. A `JournalingSuggestion` often dates a moment as a
    /// `DateInterval` (a day-long outing, a multi-hour event); the adapter that
    /// fills this passes the interval's **start**, and the calendar-day rendering
    /// is the display layer's job, not this value's. Passing the interval's end
    /// would drift the answer to "when did we…" by up to the length of the outing.
    public let date: Date
    public let coordinate: Coordinate?

    public init(content: Content, date: Date, coordinate: Coordinate?) {
        self.content = content
        self.date = date
        self.coordinate = coordinate
    }

    /// The note this becomes, or `nil` when the moment carries no usable text.
    ///
    /// A `nil` is a moment worth skipping, not an error: a location with no place
    /// name or an event with no title has nothing a later search could match, and
    /// "a bare date is not a breadcrumb" (#52). The date and coordinate ride
    /// through unchanged — `Coordinate` is both-or-neither by construction, so a
    /// half-set location is already unrepresentable here.
    public func noteDraft() -> NoteDraft? {
        guard let content = composedText else { return nil }
        return NoteDraft(content: content, occurredAt: date, coordinate: coordinate)
    }

    /// The template text for this moment, or `nil` when there is nothing to say.
    ///
    /// Phase 3 derives the dedup key from a canonical form of these fields, not
    /// from this display string: the group list keeps Apple's order for reading,
    /// so hashing the rendered text would make a same-outing re-pull in a
    /// different order look like a new memory (#52's no-duplicate rule).
    private var composedText: String? {
        switch content {
        case let .location(place, city):
            guard let place = place.nonBlank else { return nil }
            guard let city = city?.nonBlank, !Self.place(place, alreadyNames: city) else {
                return "Visited \(place)"
            }
            return "Visited \(place), \(city)"

        case let .locationGroup(city, places):
            let usable = Self.dedupePreservingOrder(places.compactMap(\.nonBlank))
            guard !usable.isEmpty else { return nil }
            let list = usable.joined(separator: ", ")
            guard let city = city?.nonBlank else { return "Visited \(list)" }
            return "Visited \(city): \(list)"

        case let .eventPoster(title, place):
            let place = place?.nonBlank
            guard let title = title.nonBlank else {
                // A poster whose OCR caught the venue but missed the title is still
                // a breadcrumb worth keeping: the venue and the date are both
                // usable, so fall back to the venue rather than dropping a moment
                // the user selected. Only a poster with neither is skipped.
                guard let place else { return nil }
                return "Visited \(place)"
            }
            guard let place else { return "Attended \(title)" }
            return "Attended \(title) at \(place)"
        }
    }

    /// Whether `place` already carries `city`, so appending it again would double
    /// it. Apple sometimes returns a place pre-qualified with its locality
    /// ("Galleria dell'Accademia, Firenze"), and sometimes the place simply is the
    /// city ("Firenze"); both would otherwise read "…, Firenze, Firenze".
    private static func place(_ place: String, alreadyNames city: String) -> Bool {
        place.caseInsensitiveCompare(city) == .orderedSame
            || place.lowercased().hasSuffix(", \(city.lowercased())")
    }

    /// Places with case-insensitive duplicates removed, first occurrence kept.
    ///
    /// Apple can list the same place twice in one group; a note reading "Duomo,
    /// Duomo" is noise. Order-preserving so the reading order still matches the
    /// outing; Phase 3's key canonicalizes further (sorted) for the hash.
    private static func dedupePreservingOrder(_ places: [String]) -> [String] {
        var seen = Set<String>()
        return places.filter { seen.insert($0.lowercased()).inserted }
    }
}
