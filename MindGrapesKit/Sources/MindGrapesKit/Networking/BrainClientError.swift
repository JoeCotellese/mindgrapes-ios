// ABOUTME: The typed failures of a capture-door request and whether each is worth retrying.
// ABOUTME: SPEC 6.3's error table is the contract; the queue reads the retry class, not the status.

import Foundation

/// What the queue should do with a failed attempt (SPEC 6.3, 8.3).
///
/// Separate from the error itself so item 5's state machine never switches on a
/// status code. A new status is classified here once and every caller inherits
/// the decision.
public enum RetryDisposition: Sendable, Equatable {
    /// Nothing will change on a second attempt. Mark the record failed, keep it
    /// visible with its error.
    case terminal

    /// Transient. Retry with backoff.
    case retry

    /// The token is the problem. SPEC 5.3 refreshes once and retries; a second
    /// `401` parks the queue rather than failing the record.
    case authRequired
}

/// Why a request to a Mind Grapes server did not produce a capture.
public enum BrainClientError: Error, Equatable, Sendable {
    /// `400`: a missing part or a malformed field. A client bug or a corrupt
    /// record, never a server hiccup.
    case badRequest

    /// `401`: the bearer was rejected.
    case unauthorized

    /// `405`: the wrong method reached the door. A client bug.
    case methodNotAllowed

    /// `413`: over `MAX_IMAGE_UPLOAD_BYTES`. Unreachable given client-side
    /// downscaling (SPEC 7.2), so it surfaces as a bug rather than a retry.
    case payloadTooLarge

    /// `415`: Pillow could not decode the bytes. The spooled file is corrupt.
    case unsupportedMediaType

    /// `502`: the embedding service is down. SPEC 6.3 states nothing was written
    /// server-side, which is what makes retrying this one safe today.
    case badGateway

    /// A status SPEC 6 does not document.
    case unexpectedStatus(Int)

    /// The request never got an answer: no route, timeout, TLS failure.
    case transport(URLError.Code)

    /// The status said success but the body was not what the endpoint promises.
    case malformedResponse

    /// A short, stable string for ``CaptureRecord/lastErrorCode``, so item 18 can
    /// show why a capture stalled without the queue storing a status code it
    /// promised never to switch on.
    public var code: String {
        switch self {
        case .badRequest: "400"
        case .unauthorized: "401"
        case .methodNotAllowed: "405"
        case .payloadTooLarge: "413"
        case .unsupportedMediaType: "415"
        case .badGateway: "502"
        case let .unexpectedStatus(status): String(status)
        case let .transport(code): "transport(\(code.rawValue))"
        case .malformedResponse: "malformed_response"
        }
    }

    public var retryDisposition: RetryDisposition {
        switch self {
        case .unauthorized:
            .authRequired
        case .badGateway, .transport:
            .retry
        case .badRequest, .methodNotAllowed, .payloadTooLarge, .unsupportedMediaType, .malformedResponse:
            .terminal
        case let .unexpectedStatus(status):
            // An undocumented 5xx is the server having a bad minute and says
            // nothing about what was written; discarding a capture over it would
            // lose data that a retry would have saved. Anything else is a
            // disagreement about the request, which a retry cannot fix.
            (500...599).contains(status) ? .retry : .terminal
        }
    }
}
