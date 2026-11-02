import Foundation
import Synchronization
import os

/// The app's only logging API, over `os.Logger`.
///
/// Never log manuscript text. The signatures enforce it: a message is a `StaticString` (a
/// literal in our source, never built at run time) and metadata values are `LogValue`s, none
/// of which can hold a runtime string. Everything that reaches the log was written by us, so
/// it's emitted with `privacy: .public` and also copied to the on-disk `LogRing`, which lets
/// a problem report include sessions that ended in a crash.
public struct Log: Sendable {
    public static let subsystem = SceneItCore.bundleIdentifier

    public static let app = Log(.app)
    public static let store = Log(.store)
    public static let backup = Log(.backup)
    public static let editor = Log(.editor)
    public static let diagnostics = Log(.diagnostics)

    public let category: LogCategory
    private let logger: Logger

    private init(_ category: LogCategory) {
        self.category = category
        logger = Logger(subsystem: Self.subsystem, category: category.rawValue)
    }

    public func debug(_ message: StaticString, _ metadata: LogMetadata = [:]) {
        record(.debug, message, metadata)
    }

    public func info(_ message: StaticString, _ metadata: LogMetadata = [:]) {
        record(.info, message, metadata)
    }

    public func error(_ message: StaticString, _ metadata: LogMetadata = [:]) {
        record(.error, message, metadata)
    }

    public func fault(_ message: StaticString, _ metadata: LogMetadata = [:]) {
        record(.fault, message, metadata)
    }

    /// Starts (or, with `nil`, stops) copying entries at `.info` and above to `ring`.
    public static func persist(to ring: LogRing?) {
        persistentRing.withLock { $0 = ring }
    }

    private static let persistentRing = Mutex<LogRing?>(nil)

    private func record(_ level: LogLevel, _ message: StaticString, _ metadata: LogMetadata) {
        let text = Self.compose(message, metadata)
        logger.log(level: level.osLogType, "\(text, privacy: .public)")
        guard level != .debug, let ring = Self.persistentRing.withLock({ $0 }) else { return }
        ring.append(LogEntry(date: .now, level: level, category: category.rawValue, message: text))
    }

    static func compose(_ message: StaticString, _ metadata: LogMetadata) -> String {
        metadata.reduce(message.description) { text, pair in
            "\(text) \(pair.key)=\(pair.value.rendered)"
        }
    }
}

extension LogLevel {
    fileprivate var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .error: .error
        case .fault: .fault
        }
    }
}
