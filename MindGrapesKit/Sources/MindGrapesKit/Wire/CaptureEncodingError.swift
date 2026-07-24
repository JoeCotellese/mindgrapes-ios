// ABOUTME: The refusals the capture-door encoders raise instead of emitting a malformed request.
// ABOUTME: Every case is a client bug, so the queue treats them as terminal rather than retrying.

import Foundation

/// Why a `CaptureRecord` could not be turned into a request body.
///
/// None of these are transient. SPEC 6.3 classifies the matching server answer
/// (`400`) as terminal, and the encoder catches the same conditions one hop
/// earlier, before a doomed request leaves the device.
public enum CaptureEncodingError: Error, Equatable, Sendable {
    /// A note record was handed to the image door, or the reverse.
    case wrongKind(expected: CaptureKind, actual: CaptureKind)

    /// `content` is the one required field on SPEC 6.4's body.
    case missingContent

    /// A photo record with no spool file to read bytes from.
    case missingImageFilename

    /// A photo record names a spool file, but the bytes could not be read: the
    /// derivative was deleted, never finished writing, or the container moved.
    /// Terminal, since a downscaled derivative cannot be rebuilt from the record.
    case spoolFileUnreadable(String)

    /// The caller supplied a boundary that is empty, over 70 characters, or
    /// carries something outside the token characters RFC 2046 allows.
    case invalidBoundary(String)

    /// The caller's boundary occurs inside the payload, where it would split a
    /// part in half. Generated boundaries retry instead of failing.
    case boundaryCollision(String)

    /// The id handed to ``CaptureQueue/noteBody(id:timeZone:)`` names no record:
    /// a drain racing a prune, or a stale id. The caller skips it.
    case recordNotFound(UUID)
}
