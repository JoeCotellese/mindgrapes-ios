// ABOUTME: The durable outbox row for one capture, persisted with SwiftData.
// ABOUTME: Metadata only: image bytes live in the App Group spool, never in the database.

import Foundation
import SwiftData

/// One capture waiting to reach the server, or one that already did.
///
/// The field list is SPEC 8.1. `id` doubles as the `idempotency_key` (SPEC
/// 6.5): it is minted with the record, stored before the first network
/// attempt, and reused verbatim on every retry, which is what turns a crash
/// between "server committed" and "client marked done" into exactly-once.
///
/// **Not `Sendable`, deliberately.** SwiftData `@Model` classes are mutable
/// reference types bound to a `ModelContext`, which is itself not `Sendable`.
/// Item 5 confines every instance inside the `CaptureQueue` actor and hands
/// out value snapshots; passing a record across isolation boundaries is a bug,
/// and the missing conformance is what makes the compiler say so.
@Model
public final class CaptureRecord {
    /// Also the `idempotency_key` on both capture doors (SPEC 6.5). Unique so
    /// a re-enqueue of the same capture collides instead of duplicating.
    @Attribute(.unique) public var id: UUID

    /// Backing storage for ``kind``. Stored raw because `#Predicate` can only
    /// see stored attributes, and item 5 filters on this.
    var kindRaw: String

    // MARK: Capture payload

    /// The user's words. Set for notes, `nil` for photos.
    public var content: String?
    public var occurredAt: Date

    /// Half of a location fix. Internal on purpose: ``coordinate`` is the only
    /// supported way in or out, so a half-set fix cannot reach the wire, where
    /// SPEC 6.3 requires both or neither.
    var lat: Double?
    var lng: Double?

    /// The reverse-geocoded label. `/capture/note` takes it as `place_label`;
    /// the image door has nowhere to put it yet (SPEC 9), so it is kept
    /// locally for a later resend rather than dropped.
    public var placeLabel: String?

    public var people: [Person]
    public var labels: [String]

    /// The generated (or typed, or templated) statement for a photo. Named
    /// `captureDescription` rather than SPEC 8.1's `description` because a
    /// stored `description` on a class shadows the debugging text every Swift
    /// value has; the wire field is still `description`.
    public var captureDescription: String?

    /// Detected text from Vision, sent as `ocr_text`.
    public var ocrText: String?

    /// Optional event name the server links as an entity.
    public var event: String?

    /// The spool file in the App Group container. SPEC 8.1: never image bytes
    /// in the database.
    public var imageFilename: String?

    // MARK: Queue bookkeeping

    /// Backing storage for ``state``; see ``kindRaw`` for why it is raw.
    var stateRaw: String

    public var attemptCount: Int
    public var nextAttemptAt: Date
    public var lastErrorCode: String?
    public var createdAt: Date

    /// The server's `experience_id`, kept after success so the record can back
    /// the recent-captures list until it is pruned (SPEC 8.1). A `String`
    /// rather than a `UUID` so an unexpected identifier shape from the server
    /// is recorded rather than discarded.
    public var experienceID: String?

    /// The designated initializer. Prefer the draft-based initializers below;
    /// this one exists so item 5 can rehydrate a record from arbitrary state.
    public init(
        id: UUID = UUID(),
        kind: CaptureKind,
        content: String? = nil,
        occurredAt: Date,
        coordinate: Coordinate? = nil,
        placeLabel: String? = nil,
        people: [Person] = [],
        labels: [String] = [],
        captureDescription: String? = nil,
        ocrText: String? = nil,
        event: String? = nil,
        imageFilename: String? = nil,
        state: CaptureState = .pending,
        attemptCount: Int = 0,
        nextAttemptAt: Date? = nil,
        lastErrorCode: String? = nil,
        experienceID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.content = content
        self.occurredAt = occurredAt
        self.lat = coordinate?.latitude
        self.lng = coordinate?.longitude
        self.placeLabel = placeLabel
        self.people = people
        self.labels = labels
        self.captureDescription = captureDescription
        self.ocrText = ocrText
        self.event = event
        self.imageFilename = imageFilename
        self.stateRaw = state.rawValue
        self.attemptCount = attemptCount
        // A record is due the moment it exists; the first attempt happens
        // inline (SPEC 8.4) and backoff only ever pushes this forward.
        self.nextAttemptAt = nextAttemptAt ?? createdAt
        self.lastErrorCode = lastErrorCode
        self.experienceID = experienceID
        self.createdAt = createdAt
    }

    public convenience init(id: UUID = UUID(), note: NoteDraft, createdAt: Date = Date()) {
        self.init(
            id: id,
            kind: .note,
            content: note.content,
            occurredAt: note.occurredAt,
            coordinate: note.coordinate,
            placeLabel: note.placeLabel,
            people: note.people,
            labels: note.labels,
            createdAt: createdAt
        )
    }

    public convenience init(id: UUID = UUID(), photo: PhotoDraft, createdAt: Date = Date()) {
        self.init(
            id: id,
            kind: .photo,
            occurredAt: photo.occurredAt,
            coordinate: photo.coordinate,
            placeLabel: photo.placeLabel,
            people: photo.people,
            labels: photo.labels,
            captureDescription: photo.description,
            ocrText: photo.ocrText,
            event: photo.event,
            imageFilename: photo.imageFilename,
            createdAt: createdAt
        )
    }

    // MARK: Typed accessors over the raw storage

    public var kind: CaptureKind {
        get { CaptureKind(rawValue: kindRaw) ?? .note }
        set { kindRaw = newValue.rawValue }
    }

    public var state: CaptureState {
        get { CaptureState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    /// The location fix, or `nil` if there is none.
    ///
    /// Reading rebuilds a validated ``Coordinate``, so a row with only one half
    /// populated reads as no location instead of producing the `400` that
    /// SPEC 6.3 promises for a lone `lat`.
    public var coordinate: Coordinate? {
        get {
            guard let lat, let lng else { return nil }
            return Coordinate(latitude: lat, longitude: lng)
        }
        set {
            lat = newValue?.latitude
            lng = newValue?.longitude
        }
    }

    /// The value sent as `idempotency_key` on both capture doors (SPEC 6.5).
    public var idempotencyKey: String { id.uuidString }
}
