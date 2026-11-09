import Foundation

/// Makes ULIDs: 26 Crockford base-32 characters encoding a 48-bit millisecond timestamp
/// followed by 80 random bits. Ids sort by creation time to the millisecond; within one
/// millisecond their order is random.
public struct IDGenerator<Source: RandomNumberGenerator> {
    private let now: () -> Date
    private var random: Source

    public init(now: @escaping () -> Date, random: Source) {
        self.now = now
        self.random = random
    }

    public mutating func sceneID() -> SceneID {
        SceneID(rawValue: ulid())
    }

    public mutating func commentID() -> CommentID {
        CommentID(rawValue: ulid())
    }

    public mutating func exportID() -> ExportID {
        ExportID(rawValue: ulid())
    }

    private mutating func ulid() -> String {
        let milliseconds = UInt64(max(0, (now().timeIntervalSince1970 * 1000).rounded(.down)))
        let time = UInt128(min(milliseconds, (1 << 48) - 1))
        let randomBits =
            UInt128(UInt16.random(in: .min ... .max, using: &random)) << 64 | UInt128(random.next())
        let value = time << 80 | randomBits
        return String((0..<26).reversed().map { digit in crockford[Int(value >> (digit * 5) & 0x1F)] })
    }
}

extension IDGenerator where Source == SystemRandomNumberGenerator {
    public static var system: Self {
        IDGenerator(now: Date.init, random: SystemRandomNumberGenerator())
    }
}

private let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
