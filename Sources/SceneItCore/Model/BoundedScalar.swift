public protocol ScalarBounds: Sendable {
    associatedtype Value: BinaryFloatingPoint & Codable & Sendable
    static var range: ClosedRange<Value> { get }
    /// The value a new book starts with.
    static var standard: Value { get }
}

/// A floating-point value confined to `Bounds.range`. Encoded as a bare number; decoding
/// rejects a value outside the range instead of clamping it.
///
/// Clamping NaN gives `Bounds.standard`, so ordering is total. `-0` is stored as `0`, so
/// values that compare equal also encode identically.
public struct Bounded<Bounds: ScalarBounds>: Comparable, Hashable, Codable, Sendable {
    public let value: Bounds.Value

    public static var standard: Self {
        Self(clamping: Bounds.standard)
    }

    public init(clamping value: Bounds.Value) {
        let range = Bounds.range
        self.value = value.isNaN ? Bounds.standard : min(max(value, range.lowerBound), range.upperBound) + 0
    }

    public init?(exactly value: Bounds.Value) {
        guard Bounds.range.contains(value) else { return nil }
        self.value = value + 0
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Bounds.Value.self)
        guard let bounded = Self(exactly: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\(raw) is outside the allowed range \(Bounds.range)")
        }
        self = bounded
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// `AVSpeechUtterance.rate`, whose minimum and maximum are 0 and 1.
public typealias SpeechRate = Bounded<SpeechRateBounds>

public enum SpeechRateBounds: ScalarBounds {
    public static let range: ClosedRange<Float> = 0...1
    public static let standard: Float = 0.5
}

extension Float {
    public init(_ rate: SpeechRate) {
        self = rate.value
    }
}
