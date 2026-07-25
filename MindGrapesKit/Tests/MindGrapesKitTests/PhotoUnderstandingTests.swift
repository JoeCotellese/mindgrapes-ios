// ABOUTME: Proves the photo-understanding selection order: user words, else model, else template.
// ABOUTME: Runs entirely against fakes; the real Vision/Foundation Models paths are device/sim-verified.

import Foundation
import Testing

@testable import MindGrapesKit

@Suite struct PhotoUnderstandingTests {
    private struct StubRecognizer: TextRecognizing {
        let text: String
        func recognizeText(in imageData: Data) async -> String { text }
    }

    /// `output == nil` makes generation throw, standing in for a model failure.
    private struct StubGenerator: DescriptionGenerating {
        let available: Bool
        var output: String?
        var isAvailable: Bool { available }
        func generateDescription(ocrText: String, occurredAt: Date, timeZone: TimeZone) async throws -> String {
            guard let output else { throw DescriptionGenerationError.unavailable }
            return output
        }
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let utc = TimeZone(identifier: "UTC")!
    private let bytes = Data("not a real image".utf8)

    @Test func aUserSuppliedDescriptionAlwaysWins() async {
        let understanding = PhotoUnderstanding(
            recognizer: StubRecognizer(text: "OCR TEXT"),
            generator: StubGenerator(available: true, output: "MODEL TEXT")
        )
        let result = await understanding.understand(
            imageData: bytes, userDescription: "my own words", occurredAt: now, timeZone: utc
        )
        #expect(result.description == "my own words")
        // OCR still rides along even when the human worded the description.
        #expect(result.ocrText == "OCR TEXT")
    }

    @Test func theModelIsUsedWhenAvailableAndNoUserDescription() async {
        let understanding = PhotoUnderstanding(
            recognizer: StubRecognizer(text: "OCR TEXT"),
            generator: StubGenerator(available: true, output: "a salmon dog food label")
        )
        let result = await understanding.understand(imageData: bytes, occurredAt: now, timeZone: utc)
        #expect(result.description == "a salmon dog food label")
        #expect(result.ocrText == "OCR TEXT")
    }

    @Test func anUnavailableModelFallsToTheTemplateWithOCRFoldedIn() async {
        let understanding = PhotoUnderstanding(
            recognizer: StubRecognizer(text: "SALMON RECIPE"),
            generator: StubGenerator(available: false, output: "unused")
        )
        let result = await understanding.understand(imageData: bytes, occurredAt: now, timeZone: utc)
        #expect(result.description.contains("SALMON RECIPE"))
        #expect(result.description.contains("2023"))
        #expect(result.ocrText == "SALMON RECIPE")
    }

    @Test func aThrowingModelFallsToTheTemplate() async {
        let understanding = PhotoUnderstanding(
            recognizer: StubRecognizer(text: "SALMON RECIPE"),
            generator: StubGenerator(available: true, output: nil)  // throws
        )
        let result = await understanding.understand(imageData: bytes, occurredAt: now, timeZone: utc)
        #expect(result.description.contains("SALMON RECIPE"))
    }

    @Test func aBlankModelOutputFallsToTheTemplate() async {
        let understanding = PhotoUnderstanding(
            recognizer: StubRecognizer(text: "SALMON RECIPE"),
            generator: StubGenerator(available: true, output: "   ")
        )
        let result = await understanding.understand(imageData: bytes, occurredAt: now, timeZone: utc)
        #expect(result.description.contains("SALMON RECIPE"))
    }

    @Test func noOCRYieldsNilOCRTextAndATimestampDescription() async {
        let understanding = PhotoUnderstanding(
            recognizer: StubRecognizer(text: ""),
            generator: StubGenerator(available: false, output: nil)
        )
        let result = await understanding.understand(imageData: bytes, occurredAt: now, timeZone: utc)
        #expect(result.ocrText == nil)
        #expect(result.description.hasPrefix("Photo captured"))
    }

    @Test func theDefaultCompositionPreservesSlice2Behavior() async {
        // DisabledTextRecognizer + TemplateOnlyDescriptionGenerator is the runner's
        // default; it must reproduce the pre-Slice-6 timestamp-only description.
        let understanding = PhotoUnderstanding(
            recognizer: DisabledTextRecognizer(),
            generator: TemplateOnlyDescriptionGenerator()
        )
        let result = await understanding.understand(imageData: bytes, occurredAt: now, timeZone: utc)
        #expect(result.ocrText == nil)
        #expect(result.description == PhotoDescription.template(occurredAt: now, timeZone: utc))
    }
}
