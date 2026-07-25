// ABOUTME: Proves the fallback photo description is non-empty and names the capture time.
// ABOUTME: This is the wording Slice 2's screen and Slice 4's photo intent fall back to.

import Foundation
import Testing

@testable import MindGrapesKit

@Suite struct PhotoDescriptionTests {
    @Test func templateIsNonBlankSoItSatisfiesPhotoDraft() throws {
        let text = PhotoDescription.template(occurredAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(text.nonBlank != nil)
        // It must actually construct a PhotoDraft, which rejects a blank description.
        #expect(PhotoDraft(imageFilename: "x.jpg", description: text) != nil)
    }

    @Test func templateNamesTheYear() {
        // A fixed instant in a fixed zone so the assertion is deterministic.
        let text = PhotoDescription.template(
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(text.contains("2023"))
    }

    @Test func templateFoldsInOCRTextWhenPresent() {
        let text = PhotoDescription.template(
            ocrText: "PURINA ONE\nSALMON RECIPE",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: TimeZone(identifier: "UTC")!
        )
        // The label's own words lead, newlines flattened, timestamp trailing.
        #expect(text.contains("PURINA ONE SALMON RECIPE"))
        #expect(text.contains("2023"))
        #expect(!text.contains("\n"))
        #expect(PhotoDraft(imageFilename: "x.jpg", description: text) != nil)
    }

    @Test func templateCapsAVeryLongOCRRun() {
        let longOCR = String(repeating: "A", count: 5000)
        let text = PhotoDescription.template(
            ocrText: longOCR,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: TimeZone(identifier: "UTC")!
        )
        // A full-page OCR must not produce a multi-thousand-char description; it is
        // truncated with an ellipsis, and the timestamp still trails.
        #expect(text.count < 400)
        #expect(text.contains("…"))
        #expect(text.contains("2023"))
    }

    @Test func templateWithBlankOCRIsTimestampOnly() {
        let withBlank = PhotoDescription.template(
            ocrText: "   ",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: TimeZone(identifier: "UTC")!
        )
        let withNil = PhotoDescription.template(
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: TimeZone(identifier: "UTC")!
        )
        // Blank OCR is treated as no OCR: identical to the timestamp-only form.
        #expect(withBlank == withNil)
        #expect(withBlank.hasPrefix("Photo captured"))
    }
}
