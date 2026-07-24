// ABOUTME: A foreground drain pass that sends due note captures and records each outcome.
// ABOUTME: ponytail: throwaway Slice-1 glue; the background uploader (item 6) replaces it wholesale.

import Foundation

/// One synchronous-ish pass over the outbox: claim what is due, send each note,
/// tell the queue what happened.
///
/// This is the minimum that takes a typed note all the way to a real
/// `experience_id`. It has no timer, no background session, and no concurrency
/// of its own; the app calls ``drainOnce(now:)`` on save and on foreground.
/// Item 6 brings the durable background version.
///
/// The token comes from an injected closure rather than an `AuthManager`
/// directly, so the loop stays decoupled from auth and trivially testable: a
/// test hands it a closure, production hands it `authManager.validAccessToken`.
public struct NoteDrainer: Sendable {
    private let queue: CaptureQueue
    private let client: BrainClient
    private let timeZone: TimeZone
    private let accessToken: @Sendable () async throws -> String

    /// - Parameters:
    ///   - queue: the outbox actor, the single writer for capture state.
    ///   - client: the transport for `/capture/note`.
    ///   - timeZone: the zone `occurred_at` is expressed in; the device's by
    ///     default, so the offset in the wire string means something to a human.
    ///   - accessToken: yields a valid bearer, refreshing if needed. Throwing
    ///     ``AuthError/authRequired`` parks the queue (a dead refresh); any other
    ///     throw aborts the pass and leaves the claimed records `inFlight`, which
    ///     the next pass's reclaim returns to `pending`.
    public init(
        queue: CaptureQueue,
        client: BrainClient,
        timeZone: TimeZone = .current,
        accessToken: @escaping @Sendable () async throws -> String
    ) {
        self.queue = queue
        self.client = client
        self.timeZone = timeZone
        self.accessToken = accessToken
    }

    /// Sends every note due at `now` and returns the fresh snapshots of the
    /// records it touched, so a caller can show the outcome.
    ///
    /// Reclaims anything a prior aborted pass left `inFlight` before claiming, so
    /// a transient failure self-heals on the next call instead of stranding a
    /// record until relaunch. That reclaim is only safe because ``CaptureQueue``
    /// runs one drain at a time (``CaptureQueue/beginDrain()``): without the gate
    /// this pass could reset a *concurrent* pass's in-flight record and re-send
    /// it. A duplicate send is still harmless — the `idempotency_key` (SPEC 6.5)
    /// makes the server dedupe — but the gate keeps retry accounting honest.
    ///
    /// Returns `[]` immediately when another drain is already running.
    @discardableResult
    public func drainOnce(now: Date = Date()) async throws -> [CaptureSnapshot] {
        guard await queue.beginDrain() else { return [] }
        do {
            let result = try await drain(now: now)
            await queue.endDrain()
            return result
        } catch {
            await queue.endDrain()
            throw error
        }
    }

    private func drain(now: Date) async throws -> [CaptureSnapshot] {
        try await queue.recoverInterrupted(now: now)

        let due = try await queue.claimDue(now: now)
        guard !due.isEmpty else { return [] }

        let token: String
        do {
            token = try await accessToken()
        } catch AuthError.authRequired {
            // The refresh token is dead (SPEC 8.5): hold the whole queue for
            // re-auth rather than failing captures. resumeAfterAuth revives them.
            try await queue.parkForAuth()
            return try await snapshots(of: due.map(\.id))
        }
        // Any other token error (transport, no stored tokens) aborts the pass.
        // The claimed records stay inFlight and this pass's recoverInterrupted
        // reclaims them next time.

        for snapshot in due {
            do {
                let body = try await queue.noteBody(id: snapshot.id, timeZone: timeZone)
                let response = try await client.postNote(body: body, accessToken: token)
                try await queue.markSucceeded(id: snapshot.id, experienceID: response.experienceID)
            } catch let error as BrainClientError {
                // The queue classifies by disposition: terminal fails the record,
                // retryable backs it off, a lone 401 holds it due-now for the
                // refresh-and-retry on the next pass (SPEC 8.3).
                try await queue.markFailed(id: snapshot.id, error: error, now: now)
            }
            // A CaptureEncodingError is left to propagate: with a NoteDraft's
            // guaranteed content it cannot happen for a note, so treating it as a
            // real bug rather than swallowing it is correct.
        }

        return try await snapshots(of: due.map(\.id))
    }

    private func snapshots(of ids: [UUID]) async throws -> [CaptureSnapshot] {
        var result: [CaptureSnapshot] = []
        for id in ids {
            if let snapshot = try await queue.snapshot(id: id) { result.append(snapshot) }
        }
        return result
    }
}
