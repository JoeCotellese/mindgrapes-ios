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
}
