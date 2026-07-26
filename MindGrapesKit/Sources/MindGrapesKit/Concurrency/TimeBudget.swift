// ABOUTME: Runs an async operation under a wall-clock ceiling, yielding nil when it elapses.
// ABOUTME: One implementation so every "location must not delay a capture" rule bounds the same way.

import Foundation

/// Runs `operation`, returning `nil` if `budget` elapses first.
///
/// The losing child is cancelled, so a still-pending CoreLocation request or
/// in-flight geocode does not leak past the deadline. Both callers use this for
/// the same reason: an operation that reaches the network must never be able to
/// delay a capture, only to lose its own result (SPEC 9).
///
/// `nil` from the operation and `nil` from the timeout are deliberately
/// indistinguishable. Every caller treats both the same way — no coordinate, or no
/// label — so a second return channel would be ceremony.
func withTimeBudget<T: Sendable>(
    _ budget: Duration,
    _ operation: @escaping @Sendable () async -> T?
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: budget)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
