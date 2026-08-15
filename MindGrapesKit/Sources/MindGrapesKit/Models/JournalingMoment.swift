// ABOUTME: One selected Journaling Suggestion, reduced to the text and metadata a note needs.
// ABOUTME: The app fills it from an un-simulatable JournalingSuggestion; all mapping logic lives here.

import CryptoKit
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
    /// ``idempotencyID`` keys off this text for a location and an event, so two
    /// renderings that read identically also dedupe. Only a group is rebuilt for
    /// the key (its places sorted): a group is the one kind whose reading order is
    /// preserved here for the note, and that order must not leak into the id, or a
    /// same-outing re-pull in another order would look like a new memory (#52).
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
                //
                // This reads exactly like a location breadcrumb, and because its
                // kind still differs it will not dedupe against a location
                // suggestion for the same venue in the same minute — two identical
                // lines. Accepted: it needs a titleless poster and a separate
                // location suggestion for one venue at one time, which is rare.
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

    // MARK: - Idempotency

    /// The id to enqueue this moment under, stable across re-pulls of the same
    /// suggestion so ``CaptureQueue/enqueue(note:id:now:)`` dedupes it rather than
    /// writing a second memory (#52).
    ///
    /// Derived, not random: Apple's picker exposes no stable suggestion id outside
    /// the notification flow (a Phase 0 device spike may find one and supersede
    /// this). The id is a name-based UUID over a canonical signature — the kind,
    /// the moment's canonical text, and the visit bucketed to the minute.
    ///
    /// Two things are deliberately absent. The **coordinate**: it is redundant with
    /// the place text and is the largest source of between-pull drift (a place's
    /// fix wanders by metres), so including it would split one visit into two
    /// records far more often than it would ever separate two real visits. And
    /// **sub-minute precision**, for the same reason — the note's own `occurred_at`
    /// keeps the exact instant; the id only needs enough to tell visits apart.
    ///
    /// The text reuses ``composedText`` (a group is rebuilt with its places sorted,
    /// since only the group has an order), so the place-carries-city and place==city
    /// variants Apple alternates between key identically, and it is folded to NFC +
    /// lowercase so an accented name that arrives decomposed one pull and
    /// precomposed the next still matches. Because it keys off the rendered text, a
    /// change to the templates above changes the id: bump the `v1` tag deliberately
    /// if that happens, the way a schema migration is deliberate.
    public var idempotencyID: UUID {
        let signature = [
            "mindgrapes/journaling/v1",
            kindTag,
            Self.foldForKey(canonicalKeyText),
            String(Int((date.timeIntervalSince1970 / 60).rounded())),
        ].joined(separator: "\u{1F}")
        return uuidFromNameHash(SHA256.hash(data: Data(signature.utf8)))
    }

    private var kindTag: String {
        switch content {
        case .location: return "location"
        case .locationGroup: return "group"
        case .eventPoster: return "event"
        }
    }

    /// The moment's identity text. Location and event reuse ``composedText`` so the
    /// key sees exactly the collapse the note shows; a group is rebuilt with its
    /// places sorted (not the display's Apple order) so the id is order-independent.
    private var canonicalKeyText: String {
        switch content {
        case .location, .eventPoster:
            return composedText ?? ""
        case let .locationGroup(city, places):
            let sorted = Set(places.compactMap(\.nonBlank).map(Self.foldForKey))
                .filter { !$0.isEmpty }
                .sorted()
            guard !sorted.isEmpty else { return "" }
            let list = sorted.joined(separator: ", ")
            guard let city = city?.nonBlank else { return "Visited \(list)" }
            return "Visited \(Self.foldForKey(city)): \(list)"
        }
    }

    /// A stable byte form for hashing: drop C0 control characters (so nothing can
    /// forge a field separator), normalize to NFC, and lowercase — all
    /// locale-independent, so the same name always yields the same bytes.
    private static func foldForKey(_ value: String) -> String {
        let withoutControls = String(value.unicodeScalars.filter { $0.value >= 0x20 })
        return withoutControls.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// A deterministic UUID from a hash: the first 16 bytes, stamped as RFC 9562
/// version 8 (a custom, implementation-defined layout — honest here because the
/// bytes are SHA-256, not the SHA-1 a version-5 UUID names) with the RFC 4122
/// variant. The same hash always yields the same UUID, which is the whole point.
private func uuidFromNameHash(_ digest: SHA256.Digest) -> UUID {
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x80
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}
