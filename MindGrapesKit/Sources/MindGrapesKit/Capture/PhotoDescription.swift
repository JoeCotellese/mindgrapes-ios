// ABOUTME: The fallback description a photo carries when the user types none (SPEC 7.3 template path).
// ABOUTME: Kept tiny and testable so Slice 2's screen and Slice 4's photo intent share one wording.

import Foundation

/// The client-side description of last resort.
///
/// ``PhotoDraft`` requires a non-blank description because that is the switch
/// keeping photo bytes on the household's own server (SPEC 11): a `shared`
/// capture with no description triggers the server's off-box vision fallback.
/// Slices 2 and 4 have no OCR or on-device model yet (that is Slice 6), so when
/// the user supplies no words this composes a usable one from the timestamp.
///
/// The template fallback (SPEC 7.3): the description a photo carries when the
/// user typed none and the on-device model is unavailable or failed. It folds the
/// OCR text in when there is any, so a label photo is still useful without the
/// model (the dog-food-label case on a device with no Apple Intelligence,
/// success condition 8); with no OCR it names when the photo was taken.
public enum PhotoDescription {
    /// A non-empty description composed from the detected text and the timestamp.
    ///
    /// `ocrText` defaults to `nil` so existing timestamp-only callers are
    /// unchanged; when present, the detected text (newlines flattened to spaces)
    /// leads so the description reads as the label's own words.
    public static func template(
        ocrText: String? = nil,
        occurredAt: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let stamp = WireTimestamp.string(from: occurredAt, in: timeZone)
        guard let ocr = ocrText?.nonBlank else {
            return "Photo captured \(stamp)"
        }
        let flattened = ocr
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Cap the folded OCR: a full-page document would otherwise make a
        // multi-thousand-character description that reads nothing like a
        // standalone statement and, doubled with the full ocr_text field, pushes
        // the body toward the server's size limit. The complete text still travels
        // in ocr_text; this is only the human-readable description.
        let condensed = flattened.count > maxFoldedOCRLength
            ? String(flattened.prefix(maxFoldedOCRLength)) + "…"
            : flattened
        return "\(condensed) (photo captured \(stamp))"
    }

    /// The longest OCR run folded into the description. Roughly a sentence or two;
    /// enough for a label, short of a page.
    private static let maxFoldedOCRLength = 240
}
