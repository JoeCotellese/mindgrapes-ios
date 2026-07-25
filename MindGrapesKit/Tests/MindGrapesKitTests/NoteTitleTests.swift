// ABOUTME: Tests the title derived from a capture's text for the notes app schema.
// ABOUTME: Covers single-line, multi-line, blank, and whitespace-padded input.

import Testing

@testable import MindGrapesKit

@Suite("NoteTitle")
struct NoteTitleTests {
    @Test("a one-line capture is its own title")
    func singleLine() {
        #expect(NoteTitle.firstLine(of: "Buy the dog food with the green label") == "Buy the dog food with the green label")
    }

    @Test("a multi-line capture is titled by its first line")
    func multiLine() {
        let text = "Call the vet\nAsk about the limp, and whether the new food is the cause"
        #expect(NoteTitle.firstLine(of: text) == "Call the vet")
    }

    @Test("surrounding whitespace never reaches the title")
    func trimsPadding() {
        #expect(NoteTitle.firstLine(of: "  \n  Call the vet  \nlater") == "Call the vet")
    }

    @Test("blank input yields an empty title rather than a placeholder")
    func blankInput() {
        #expect(NoteTitle.firstLine(of: "") == "")
        #expect(NoteTitle.firstLine(of: "   \n  ") == "")
    }
}
