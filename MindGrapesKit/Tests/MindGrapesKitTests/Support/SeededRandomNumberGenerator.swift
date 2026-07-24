// ABOUTME: A deterministic RandomNumberGenerator so backoff bounds are reproducible.
// ABOUTME: SplitMix64; the system generator is not seedable, and backoff must be sampled repeatably.

/// A seeded generator for tests. SplitMix64 is enough to exercise the full
/// jitter range without pulling in a dependency.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
