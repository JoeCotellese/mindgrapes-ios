// ABOUTME: The OCR seam (item 12): turn photo bytes into detected text, best-effort.
// ABOUTME: Behind a protocol so the pipeline tests against a fake and the Vision impl stays sim-only.

import Foundation

/// Recognizes text in a photo (SPEC 7.2).
///
/// OCR is best-effort and must never fail a capture: an unreadable image, an
/// unavailable engine, or a recognizer error all resolve to `""` (no text), not
/// a thrown error. The pipeline treats empty as "no OCR" and carries on.
///
/// A seam so the photo-understanding pipeline is tested entirely against a fake;
/// the real Vision implementation is exercised on the simulator against
/// reference images, not in the unit suite.
public protocol TextRecognizing: Sendable {
    /// The detected text, newline-joined across lines, or `""` when none is found
    /// or recognition could not run.
    func recognizeText(in imageData: Data) async -> String
}

/// The default recognizer: no OCR. Keeps the pipeline's behavior identical to
/// Slice 2/4 until a real recognizer is injected, and stands in on any build
/// where Vision is unavailable.
public struct DisabledTextRecognizer: TextRecognizing {
    public init() {}
    public func recognizeText(in imageData: Data) async -> String { "" }
}
