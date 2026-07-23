// ABOUTME: A validated text capture, before it becomes a durable CaptureRecord.
// ABOUTME: Construction guarantees non-empty content so an empty capture never enqueues.

import Foundation

/// A text capture assembled by the pipeline and handed to the queue.
///
/// SPEC 7.1: content is trimmed and empty content is rejected before enqueue.
/// The failable initializer is that rejection, so every layer above it can stop
/// re-checking.
public struct NoteDraft: Sendable, Hashable {
    public let content: String
    public let occurredAt: Date
    public let coordinate: Coordinate?
    public let placeLabel: String?
    public let people: [Person]
    public let labels: [String]

    /// Returns `nil` when `content` is empty or whitespace only.
    public init?(
        content: String,
        occurredAt: Date = Date(),
        coordinate: Coordinate? = nil,
        placeLabel: String? = nil,
        people: [Person] = [],
        labels: [String] = []
    ) {
        guard let content = content.nonBlank else { return nil }
        self.content = content
        self.occurredAt = occurredAt
        self.coordinate = coordinate
        self.placeLabel = placeLabel?.nonBlank
        self.people = people
        self.labels = labels.compactMap(\.nonBlank)
    }
}
