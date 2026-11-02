import Foundation

/// `Codable` ignores keys it doesn't know and decodes `null` as an absent optional.
/// `book.json` is a contract, so every model type decodes through these helpers instead.

struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension Decoder {
    /// A keyed container that throws if the object holds a key outside `Key.allCases`.
    func strictContainer<Key: CodingKey & CaseIterable>(
        keyedBy type: Key.Type
    ) throws -> KeyedDecodingContainer<Key> {
        let everything = try container(keyedBy: AnyCodingKey.self)
        let known = Set(Key.allCases.map(\.stringValue))
        let unknown = everything.allKeys.map(\.stringValue).filter { !known.contains($0) }.sorted()
        if let first = unknown.first {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: codingPath + [AnyCodingKey(stringValue: first)],
                    debugDescription:
                        "unknown key \"\(first)\"; expected one of: \(known.sorted().joined(separator: ", "))"
                ))
        }
        return try container(keyedBy: type)
    }
}

extension KeyedDecodingContainer {
    /// Like `decodeIfPresent`, except that an explicit `null` is an error rather than `nil`.
    func decodeUnlessAbsent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        contains(key) ? try decode(type, forKey: key) : nil
    }

    func corrupted(_ key: Key, _ description: String) -> DecodingError {
        .dataCorruptedError(forKey: key, in: self, debugDescription: description)
    }
}

/// A string-backed enum whose unknown values fail with a message listing the valid ones.
public protocol StrictStringEnum: RawRepresentable, CaseIterable, Codable, Sendable
where RawValue == String {}

extension StrictStringEnum {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            let valid = Self.allCases.map(\.rawValue).joined(separator: ", ")
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unknown value \"\(raw)\"; expected one of: \(valid)")
        }
        self = value
    }
}
