// ABOUTME: Composes a photo's description + OCR from the OCR and description seams (Slice 6).
// ABOUTME: The tested selection core: user words win, else the model, else the template fallback.

import Foundation

/// Turns a photo's bytes into the two content fields a capture carries: its
/// `description` and its `ocr_text` (SPEC 7.2, 7.3).
///
/// The selection order is deliberate:
/// 1. A non-blank **user-supplied** description always wins — the human's words
///    are authoritative and the model does not second-guess them.
/// 2. Otherwise, if the on-device model is available, it composes one from the
///    OCR text and context. A model that reports unavailable, throws, or returns
///    blank falls through.
/// 3. The **template fallback** composes the OCR text and timestamp into a usable
///    description, so a capture is never left without one even with no Apple
///    Intelligence (SPEC 7.3, success condition 8).
///
/// OCR runs regardless of which description path wins, because `ocr_text` is its
/// own field: a user-worded capture still carries the detected text.
public struct PhotoUnderstanding: Sendable {
    private let recognizer: any TextRecognizing
    private let generator: any DescriptionGenerating

    public init(recognizer: any TextRecognizing, generator: any DescriptionGenerating) {
        self.recognizer = recognizer
        self.generator = generator
    }

    /// The composed content for a photo.
    public struct Result: Sendable, Equatable {
        /// The non-blank description the record will carry (required by
        /// ``PhotoDraft`` — SPEC 11's on-box-vision switch).
        public let description: String
        /// The detected text, or `nil` when none was found.
        public let ocrText: String?
    }

    public func understand(
        imageData: Data,
        userDescription: String? = nil,
        occurredAt: Date,
        timeZone: TimeZone = .current
    ) async -> Result {
        let ocr = await recognizer.recognizeText(in: imageData)
        let ocrText = ocr.nonBlank

        if let user = userDescription?.nonBlank {
            return Result(description: user, ocrText: ocrText)
        }

        if generator.isAvailable,
           let generated = try? await generator.generateDescription(
               ocrText: ocr, occurredAt: occurredAt, timeZone: timeZone
           ),
           let modelDescription = generated.nonBlank {
            return Result(description: modelDescription, ocrText: ocrText)
        }

        return Result(
            description: PhotoDescription.template(ocrText: ocrText, occurredAt: occurredAt, timeZone: timeZone),
            ocrText: ocrText
        )
    }
}
