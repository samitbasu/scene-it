import Foundation

public enum LogCategory: String, CaseIterable, Codable, Sendable {
    case app
    case store
    case backup
    case editor
    case diagnostics
}

public enum LogLevel: String, CaseIterable, Codable, Sendable {
    case debug
    case info
    case error
    case fault
}

/// A metadata value that can be logged. There is deliberately no case that carries a runtime
/// `String`: text a writer typed can't be expressed as a `LogValue`, so it can't reach a log.
public enum LogValue: Sendable {
    case count(Int)
    case bytes(Int64)
    case interval(Interval)
    case id(UUID)
    /// One of a fixed set of words chosen in code, such as a state or mode name.
    case symbol(StaticString)
    case error(LoggedError)
    /// A POSIX error number, such as `errno` after a failed system call.
    case errno(Int32)

    var rendered: String {
        switch self {
        case .count(let count): String(count)
        case .bytes(let bytes): "\(bytes)B"
        case .interval(let interval): String(format: "%.3fs", interval.timeInterval)
        case .id(let id): id.uuidString
        case .symbol(let symbol): symbol.description
        case .error(let error): error.rendered
        case .errno(let code): "errno(\(code))"
        }
    }
}

/// The identity of an error without its message: an error's description can quote a file
/// name or text, but its type, domain and code can't.
public struct LoggedError: Sendable {
    public let type: String
    public let domain: String
    public let code: Int

    public init(_ error: any Error) {
        let bridged = error as NSError
        type = String(reflecting: Swift.type(of: error))
        domain = bridged.domain
        code = bridged.code
    }

    var rendered: String { "\(type)(\(domain) \(code))" }
}

/// Ordered key/value pairs written as a dictionary literal: `["scenes": .count(3)]`.
public typealias LogMetadata = KeyValuePairs<StaticString, LogValue>
