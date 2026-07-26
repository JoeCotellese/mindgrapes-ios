// ABOUTME: Derives a short human title from a capture's text.
// ABOUTME: The notes app schema wants a title; a capture has only what was said.

import Foundation

/// A title for a capture that never had one.
///
/// The `.notes.createNote` schema requires a `name`, and MindGrapes captures are
/// a stream of text with no headings. The first line is what a person would read
/// back to recognize the note, so that is the title.
public enum NoteTitle {
    /// The first line of `text`, trimmed, or the whole thing when it is one line.
    ///
    /// Returns an empty string for empty or whitespace-only input; the caller
    /// rejects those before they reach a capture (SPEC 7.1), so this does not
    /// invent a placeholder.
    public static func firstLine(of text: String) -> String {
        guard let trimmed = text.nonBlank else { return "" }
        let line = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return String(line).nonBlank ?? ""
    }
}
