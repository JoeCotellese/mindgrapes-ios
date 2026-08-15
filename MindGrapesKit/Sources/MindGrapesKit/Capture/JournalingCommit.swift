// ABOUTME: Enqueues a batch of selected Journaling moments and reports how many were new.
// ABOUTME: The testable core of the auto-commit; the app's picker adapter only builds the moments.

import Foundation

/// The auto-commit step for a Journaling Suggestions pull (#52).
///
/// The app target's picker adapter is the only part that touches Apple's
/// framework: it turns the moments the user selected into ``JournalingMoment``
/// values and hands them here. Everything a test needs to pin — that a
/// text-less moment is skipped, that a re-pulled moment dedupes, and that the
/// reported count is the number of *new* memories — lives in this function,
/// reachable without the un-simulatable picker.
public enum JournalingCommit {
    /// Enqueues every moment that yields a note, each under its own stable id, and
    /// returns how many were newly inserted.
    ///
    /// Skips (a moment with no usable text) and duplicates (a re-pull of one
    /// already saved) both count as zero, so the number returned is exactly what
    /// the status line should claim was added — never a moment the user did not
    /// gain. Enqueue-only: the caller drives the drain afterward, so a pull made
    /// offline or signed-out parks and re-auths like any capture rather than
    /// failing here.
    @discardableResult
    public static func commit(
        _ moments: [JournalingMoment],
        to queue: CaptureQueue,
        now: Date = Date()
    ) async throws -> Int {
        var inserted = 0
        for moment in moments {
            guard let draft = moment.noteDraft() else { continue }
            if try await queue.enqueue(note: draft, id: moment.idempotencyID, now: now) == .inserted {
                inserted += 1
            }
        }
        return inserted
    }
}
