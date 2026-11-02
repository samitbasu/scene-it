import Foundation
import Synchronization

/// One log line as it appears in a problem report. Only `Log` (and `CurrentProcessLog`, which
/// reads `Log`'s own entries back from the unified log) can create one.
public struct LogEntry: Codable, Sendable, Equatable {
    public let date: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String

    init(date: Date, level: LogLevel, category: LogCategory, message: String) {
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }

    public var rendered: String {
        let stamp = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return "\(stamp) \(level.rawValue) \(category.rawValue): \(message)"
    }
}

/// A size-capped, crash-tolerant copy of our own log entries on disk, as JSON lines in two
/// files: `log.jsonl` (current) and `log.1.jsonl` (previous). When the current file would
/// exceed half the capacity it replaces the previous one, so the total stays under the cap.
/// `OSLogStore` only returns the current process's entries on macOS, so this is how a report
/// sent after a crash includes the session that crashed.
public final class LogRing: Sendable {
    public static let defaultCapacityBytes = 1_048_576

    public let directory: URL
    private let fileCapacityBytes: Int
    private let handle = Mutex<FileHandle?>(nil)

    public init(directory: URL, capacityBytes: Int = defaultCapacityBytes) {
        self.directory = directory
        fileCapacityBytes = max(capacityBytes / 2, 1)
    }

    var currentFile: URL { directory.appending(path: "log.jsonl") }
    var previousFile: URL { directory.appending(path: "log.1.jsonl") }

    /// Never throws: a log that can't be written is dropped.
    func append(_ entry: LogEntry) {
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        handle.withLock { handle in
            do {
                if handle == nil { handle = try openCurrent() }
                if let open = handle, case let end = try open.seekToEnd(),
                    end > 0, end + UInt64(line.count) > fileCapacityBytes
                {
                    try open.close()
                    handle = nil
                    try rotate()
                    handle = try openCurrent()
                }
                try handle?.write(contentsOf: line)
            } catch {
                try? handle?.close()
                handle = nil
            }
        }
    }

    /// Oldest first. A line torn by a crash, or otherwise unreadable, is skipped.
    func entries() throws -> [LogEntry] {
        let files = try handle.withLock { _ in
            try [previousFile, currentFile].filter {
                FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
            }.map { try Data(contentsOf: $0) }
        }
        let decoder = JSONDecoder()
        return files.flatMap { data in
            data.split(separator: UInt8(ascii: "\n")).compactMap {
                try? decoder.decode(LogEntry.self, from: $0)
            }
        }
    }

    private func openCurrent() throws -> FileHandle {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: currentFile.path(percentEncoded: false)) {
            try Data().write(to: currentFile)
        }
        return try FileHandle(forWritingTo: currentFile)
    }

    private func rotate() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: previousFile.path(percentEncoded: false)) {
            try fileManager.removeItem(at: previousFile)
        }
        try fileManager.moveItem(at: currentFile, to: previousFile)
    }
}
