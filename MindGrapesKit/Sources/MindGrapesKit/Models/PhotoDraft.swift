// ABOUTME: A validated photo capture referencing a spooled derivative by filename.
// ABOUTME: Holds metadata only; the JPEG bytes live in the App Group spool directory.

import Foundation

/// A photo capture assembled by the pipeline and handed to the queue.
///
/// The draft names a spool file rather than carrying bytes, matching SPEC 8.1's
/// rule that image bytes never enter the database.
///
/// A description is required, not optional. SPEC 11: the server's OpenRouter
/// vision fallback fires only when a capture is `shared` *and* carries no
/// description, so "always supply a description" is the client-side switch that
/// keeps photo bytes on the household's own infrastructure. SPEC 7.3 guarantees
/// one exists even without Apple Intelligence, via the template fallback.
public struct PhotoDraft: Sendable, Hashable {
    public let imageFilename: String
    public let description: String
    public let ocrText: String?
    public let event: String?
    public let occurredAt: Date
    public let coordinate: Coordinate?
    public let placeLabel: String?
    public let people: [Person]
    public let labels: [String]

    /// Returns `nil` when the spool filename or the description is empty.
    public init?(
        imageFilename: String,
        description: String,
        ocrText: String? = nil,
        event: String? = nil,
        occurredAt: Date = Date(),
        coordinate: Coordinate? = nil,
        placeLabel: String? = nil,
        people: [Person] = [],
        labels: [String] = []
    ) {
        guard let imageFilename = imageFilename.nonBlank,
              let description = description.nonBlank
        else { return nil }
        self.imageFilename = imageFilename
        self.description = description
        self.ocrText = ocrText?.nonBlank
        self.event = event?.nonBlank
        self.occurredAt = occurredAt
        self.coordinate = coordinate
        self.placeLabel = placeLabel?.nonBlank
        self.people = people
        self.labels = labels.compactMap(\.nonBlank)
    }
}
