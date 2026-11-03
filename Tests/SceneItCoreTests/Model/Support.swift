import Foundation
import Testing

@testable import SceneItCore

/// Sebastiano Vigna's SplitMix64: a tiny seeded generator, so generated books are reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func timestamp(_ text: String) throws -> Timestamp {
    try #require(Timestamp(text))
}

/// Every line or paragraph separator `Character.isLineBreak` recognizes.
let lineBreaks = ["\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]
