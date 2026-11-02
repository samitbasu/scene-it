import AppKit

/// The attributes Scene It adds to text, typed for `AttributedString`.
///
/// The palette names, not the `NSColor`s, are what gets saved. Inside an
/// `NSAttributedString` (and so in `NSTextStorage`) every value is a property-list object
/// (`NSString`, or an `NSSet` of them), so an archived copy of the text keeps them.
public struct NovelAttributes: AttributeScope {
    public let textColor: TextColorAttribute
    public let highlight: HighlightAttribute
    public let comments: CommentsAttribute
    public let appKit: AttributeScopes.AppKitAttributes

    public enum TextColorAttribute: PaletteNameAttribute {
        public typealias Value = TextColor
        public static let name = "SceneIt.textColor"
    }

    public enum HighlightAttribute: PaletteNameAttribute {
        public typealias Value = HighlightColor
        public static let name = "SceneIt.highlight"
    }

    /// The ids of every comment covering the text. Overlapping comments put several ids
    /// on the same characters.
    public enum CommentsAttribute: ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = Set<CommentID>
        public typealias ObjectiveCValue = NSSet
        public static let name = "SceneIt.comments"

        public static func objectiveCValue(for value: Set<CommentID>) -> NSSet {
            NSSet(array: value.map(\.rawValue))
        }

        public static func value(for object: NSSet) throws -> Set<CommentID> {
            Set(
                try object.map { element in
                    guard let id = element as? String else { throw NovelAttributeError.notAString }
                    return CommentID(rawValue: id)
                })
        }
    }
}

/// A palette name stored as its raw string.
public protocol PaletteNameAttribute: ObjectiveCConvertibleAttributedStringKey
where Value: RawRepresentable<String>, ObjectiveCValue == NSString {}

extension PaletteNameAttribute {
    public static func objectiveCValue(for value: Value) -> NSString {
        value.rawValue as NSString
    }

    public static func value(for object: NSString) throws -> Value {
        guard let value = Value(rawValue: object as String) else {
            throw NovelAttributeError.unknownName(object as String)
        }
        return value
    }
}

public enum NovelAttributeError: Error, Hashable {
    case notAString
    case unknownName(String)
}

extension AttributeScopes {
    public var novel: NovelAttributes.Type { NovelAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<NovelAttributes, T>
    ) -> T {
        self[T.self]
    }
}

extension NSAttributedString.Key {
    public static let textColor = Self(NovelAttributes.TextColorAttribute.name)
    public static let highlight = Self(NovelAttributes.HighlightAttribute.name)
    /// Strip this from `typingAttributes` on every selection change (PLAN §8.1).
    public static let comments = Self(NovelAttributes.CommentsAttribute.name)
}

extension [NSAttributedString.Key: Any] {
    /// The typed value of one of our attributes; `nil` when absent or malformed.
    subscript<K: ObjectiveCConvertibleAttributedStringKey>(novel key: K.Type) -> K.Value? {
        get {
            (self[NSAttributedString.Key(K.name)] as? K.ObjectiveCValue).flatMap { try? K.value(for: $0) }
        }
        set {
            self[NSAttributedString.Key(K.name)] = newValue.flatMap { try? K.objectiveCValue(for: $0) }
        }
    }
}
