/// A string id that can't be mixed up with an id of another kind: `Owner` is a phantom
/// type, so a `SceneID` is not a `CommentID` even though both encode as a bare string.
public struct Identifier<Owner>: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension Identifier: CustomStringConvertible {
    public var description: String { rawValue }
}

public typealias SceneID = Identifier<Scene>
public typealias CommentID = Identifier<Comment>
