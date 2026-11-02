import Foundation

/// The only place that configures JSON coding for book data. Output is pretty-printed
/// with sorted keys, so encoding a given `Book` always produces the same bytes.
public enum BookCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// Refuses a book that `BookValidator` rejects, so nothing writes a file that won't load.
    public static func encode(_ book: Book) throws(BookEncodingError) -> Data {
        let problems = BookValidator.problems(in: book)
        guard problems.isEmpty else { throw .invalid(problems) }
        do {
            return try makeEncoder().encode(book)
        } catch {
            throw .encoderFailed(String(describing: error))
        }
    }

    /// Decodes without validating; see `BookValidator`.
    public static func decode(_ data: Data) throws(BookDecodingError) -> Book {
        do {
            return try makeDecoder().decode(Book.self, from: data)
        } catch let error as DecodingError {
            throw BookDecodingError(error)
        } catch {
            throw BookDecodingError(path: [], reason: error.localizedDescription)
        }
    }
}

public enum BookEncodingError: Error, Hashable, Sendable, CustomStringConvertible {
    case invalid([BookProblem])
    case encoderFailed(String)

    public var description: String {
        switch self {
        case .invalid(let problems):
            "the book is invalid:\n" + problems.map { "- \($0)" }.joined(separator: "\n")
        case .encoderFailed(let reason):
            "encoding failed: \(reason)"
        }
    }
}

/// A decoding failure, located by its path in the JSON document.
public struct BookDecodingError: Error, Hashable, Sendable, CustomStringConvertible {
    public let path: [String]
    public let reason: String

    init(path: [any CodingKey], reason: String) {
        self.path = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
        self.reason = reason
    }

    init(_ error: DecodingError) {
        switch error {
        case .typeMismatch(let type, let context):
            self.init(path: context.codingPath, reason: "expected \(Self.jsonKind(of: type))")
        case .valueNotFound(let type, let context):
            self.init(path: context.codingPath, reason: "expected \(Self.jsonKind(of: type)), found null")
        case .keyNotFound(let key, let context):
            self.init(path: context.codingPath + [key], reason: "missing")
        case .dataCorrupted(let context):
            let underlying = (context.underlyingError as? NSError)?.userInfo[NSDebugDescriptionErrorKey]
            self.init(path: context.codingPath, reason: (underlying as? String) ?? context.debugDescription)
        @unknown default:
            self.init(path: [], reason: String(describing: error))
        }
    }

    /// The path as it would be written in code, e.g. `scenes[0].body[2][1].color`.
    public var location: String {
        path.reduce("") { result, component in
            component.hasPrefix("[") || result.isEmpty ? result + component : result + "." + component
        }
    }

    public var description: String {
        path.isEmpty ? reason : "\(location): \(reason)"
    }

    private static func jsonKind(of type: Any.Type) -> String {
        switch type {
        case is String.Type: "a string"
        case is Bool.Type: "true or false"
        case is any BinaryInteger.Type: "an integer"
        case is any BinaryFloatingPoint.Type: "a number"
        case is [Any].Type: "an array"
        case is [String: Any].Type: "an object"
        default: "a value of type \(type)"
        }
    }
}
