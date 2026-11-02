/// A string id that can't be mixed up with an id of another kind: `Owner` is a phantom
/// type, so a `SceneID` is not a `CommentID` even though both encode as a bare string.
///
/// Equality and ordering compare UTF-8 bytes, not `String`'s canonical equivalence, so
/// two ids are the same only if they encode identically and sorting is byte-stable.
public struct Identifier<Owner>: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        for byte in rawValue.utf8 {
            hasher.combine(byte)
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }
}

extension Identifier: CustomStringConvertible {
    public var description: String { rawValue }
}

public typealias SceneID = Identifier<BookScene>
public typealias CommentID = Identifier<Comment>
