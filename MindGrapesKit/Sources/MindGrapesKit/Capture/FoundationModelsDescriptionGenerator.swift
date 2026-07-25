// ABOUTME: The Foundation Models implementation of DescriptionGenerating (item 13), device-verified.
// ABOUTME: Availability-gated so a device without Apple Intelligence falls to the template (SPEC 7.3).

#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Composes a photo description with the on-device model.
///
/// ``isAvailable`` reflects the system model's real state (Apple Intelligence
/// enabled, model present, not otherwise blocked), so the pipeline calls this
/// only when it can actually run and otherwise uses the template. The generation
/// is nondeterministic and never unit-tested; it is device-verified against the
/// dog-food-label case (item 13 acceptance).
@available(iOS 26.0, *)
public struct FoundationModelsDescriptionGenerator: DescriptionGenerating {
    public init() {}

    public var isAvailable: Bool {
        switch SystemLanguageModel.default.availability {
        case .available: true
        default: false
        }
    }

    public func generateDescription(ocrText: String, occurredAt: Date, timeZone: TimeZone) async throws -> String {
        let instructions = """
        You write one short factual sentence describing what a photo shows, for a \
        personal memory log. Treat the detected text as the primary evidence of \
        what the photo is. Do not invent details you cannot infer from that text. \
        Answer with the sentence only, no preamble.
        """
        let session = LanguageModelSession(instructions: instructions)

        let stamp = WireTimestamp.string(from: occurredAt, in: timeZone)
        let prompt: String
        if ocrText.nonBlank != nil {
            prompt = """
            Detected text on the photo:
            \(ocrText)

            The photo was captured \(stamp). Describe what it is in one sentence.
            """
        } else {
            prompt = "A photo was captured \(stamp) with no legible text. Describe it in one short neutral sentence."
        }

        let response = try await session.respond(to: prompt)
        return response.content
    }
}
#endif
