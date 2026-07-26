// ABOUTME: Remembers which wrist captures were permanently lost, across watch app terminations.
// ABOUTME: A loss the user never saw is a loss they were never told about, so it outlives the process.

import Foundation

/// The captures the wrist handed over, ran out of attempts on, and lost.
///
/// **Durable because the report has to outlive the process that made it.**
/// watchOS terminates watch apps on wrist-down, and a `didFinish` for a transfer
/// queued in one launch routinely arrives in the next — so the final failure of a
/// capture is very often delivered to a background relaunch, with the screen
/// facing nobody. A count held in memory would be discarded moments later and the
/// user would never learn the capture was gone, which is the same defect as
/// re-handing forever, just quieter.
///
/// Stores ids rather than a count so a redelivered completion for a capture
/// already given up on cannot inflate the number.
///
/// This is the wrist's own bookkeeping, not shared state: the Watch cannot read
/// the phone's App Group, and the phone has no use for it.
/// `@unchecked` for the same reason ``SharedDefaults`` is: `UserDefaults` is
/// documented thread-safe but is not annotated `Sendable`.
public struct LostCaptureLog: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let key = "lostCaptures"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// How many captures are known to be gone and unreported.
    public var count: Int {
        stored.count
    }

    /// Records one lost capture. Recording the same id twice is a no-op.
    public func record(_ id: UUID) {
        var ids = stored
        guard ids.insert(id.uuidString).inserted else { return }
        defaults.set(Array(ids), forKey: Self.key)
    }

    /// Forgets every recorded loss.
    ///
    /// Called when the user captures again, because that is the one instruction
    /// the status line gives them and a prompt that outlives the action is noise.
    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    private var stored: Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }
}
