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

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}

extension String {
    /// Replaces the first occurrence of `target`, which must exist.
    func replacingFirst(_ target: String, with replacement: String) throws -> String {
        let range = try #require(range(of: target), "\"\(target)\" not found")
        return replacingCharacters(in: range, with: replacement)
    }
}

func decodingError(_ json: String) throws -> BookDecodingError {
    try #require(throws: BookDecodingError.self) { try BookCoding.decode(Data(json.utf8)) }
}

func timestamp(_ text: String) throws -> Timestamp {
    try #require(Timestamp(text))
}
