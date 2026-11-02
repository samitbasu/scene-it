import Foundation
import Synchronization
import Testing

@testable import SceneItCore

/// A `LocalFileSystem` that records every call and can fail chosen ones, or simulate the
/// process dying at one.
final class FaultInjectingFileSystem: FileSystem {
    /// One call, naming files relative to the package so traces read like the pipeline.
    enum Call: Hashable, CustomStringConvertible {
        case inspect(String)
        case read(String)
        case writeTemporary(String)
        case publish(String)
        case discard(String)
        case move(String, over: String)
        case createDirectory(String)

        var isMutation: Bool {
            switch self {
            case .inspect, .read: false
            case .writeTemporary, .publish, .discard, .move, .createDirectory: true
            }
        }

        var description: String {
            switch self {
            case .inspect(let name): "inspect \(name)"
            case .read(let name): "read \(name)"
            case .writeTemporary(let name): "write a temporary file for \(name)"
            case .publish(let name): "publish \(name)"
            case .discard(let name): "discard \(name)"
            case .move(let source, let destination): "move \(source) over \(destination)"
            case .createDirectory(let name): "create directory \(name)"
            }
        }
    }

    enum Fault {
        /// Every call equal to this one fails, until `clearFault()`.
        case fail(Call)
        /// The process dies when it reaches this call: it and every later call do nothing and
        /// fail. A temporary file being written is left half-written.
        case crash(Call)
    }

    private struct State {
        var calls: [Call] = []
        var fault: Fault?
        var crashed = false
    }

    private let base = LocalFileSystem()
    private let root: URL
    private let state = Mutex(State())

    init(root: URL) {
        self.root = root
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func inject(_ fault: Fault) {
        state.withLock { $0.fault = fault }
    }

    func clearFault() {
        state.withLock { $0.fault = nil }
    }

    func clearCalls() {
        state.withLock { $0.calls = [] }
    }

    func item(at url: URL) throws(FileSystemError) -> FileItem? {
        try perform(.inspect(name(url)), .inspect, url) { () throws(FileSystemError) in try base.item(at: url)
        }
    }

    func read(_ file: URL) throws(FileSystemError) -> Data {
        try perform(.read(name(file)), .read, file) { () throws(FileSystemError) in try base.read(file) }
    }

    func writeTemporary(
        _ data: Data, for destination: URL, permissionsFrom model: URL
    ) throws(FileSystemError) -> TemporaryFile {
        let call = Call.writeTemporary(name(destination))
        if isCrash(at: call) {
            let debris = destination.deletingLastPathComponent()
                .appending(path: ".\(destination.lastPathComponent).crashed.tmp")
            try? data.prefix(data.count / 2).write(to: debris)
        }
        return try perform(call, .write, destination) { () throws(FileSystemError) in
            try base.writeTemporary(data, for: destination, permissionsFrom: model)
        }
    }

    func publish(_ temporary: TemporaryFile, as destination: URL) throws(FileSystemError) {
        try perform(.publish(name(destination)), .publish, destination) { () throws(FileSystemError) in
            try base.publish(temporary, as: destination)
        }
    }

    func discard(_ temporary: TemporaryFile) {
        try? perform(.discard(name(temporary.url)), .write, temporary.url) { () throws(FileSystemError) in
            base.discard(temporary)
        }
    }

    func move(_ source: URL, over destination: URL) throws(FileSystemError) {
        try perform(.move(name(source), over: name(destination)), .move, source) {
            () throws(FileSystemError) in
            try base.move(source, over: destination)
        }
    }

    func createDirectory(at url: URL) throws(FileSystemError) {
        try perform(.createDirectory(name(url)), .createDirectory, url) { () throws(FileSystemError) in
            try base.createDirectory(at: url)
        }
    }

    private func isCrash(at call: Call) -> Bool {
        state.withLock { state in
            if case .crash(call) = state.fault { true } else { false }
        }
    }

    private func perform<T>(
        _ call: Call, _ operation: FileSystemError.Operation, _ url: URL,
        _ body: () throws(FileSystemError) -> T
    ) throws(FileSystemError) -> T {
        let fails = state.withLock { state in
            state.calls.append(call)
            switch state.fault {
            case .fail(call): return true
            case .crash(call): state.crashed = true
            default: break
            }
            return state.crashed
        }
        guard !fails else { throw FileSystemError(operation, url, .io) }
        return try body()
    }

    private func name(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)).trimmingSlashes : path
    }
}

extension String {
    fileprivate var trimmingSlashes: String {
        String(self.drop(while: { $0 == "/" }).reversed().drop(while: { $0 == "/" }).reversed())
    }
}

/// A fresh directory under the system temporary directory, removed when `body` returns.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "SceneItTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

/// Every item under a directory: its relative path, contents and modification time.
struct DirectorySnapshot: Equatable {
    struct Entry: Equatable {
        let contents: Data?
        let modified: Date?
    }

    let entries: [String: Entry]

    init(_ root: URL) throws {
        var entries: [String: Entry] = [:]
        let manager = FileManager.default
        let enumerator = try #require(manager.enumerator(atPath: root.path(percentEncoded: false)))
        for case let path as String in enumerator {
            let url = root.appending(path: path)
            let attributes = try manager.attributesOfItem(atPath: url.path(percentEncoded: false))
            let contents: Data? =
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory?: nil
                case .typeSymbolicLink?: Data(try manager.destinationOfSymbolicLink(atPath: url.path()).utf8)
                default: try Data(contentsOf: url)
                }
            entries[path] = Entry(
                contents: contents,
                modified: attributes[.modificationDate] as? Date)
        }
        self.entries = entries
    }
}

/// Distinct, valid books: the rich fixture retitled.
func draft(_ number: Int) throws -> Book {
    var book = try RichBook.make()
    book.title = "Draft \(number)"
    return book
}

func encoded(_ book: Book) throws -> Data {
    try BookCoding.encode(book)
}

extension PackageLayout {
    /// The bytes of `book.json` and each backup slot; `nil` where a file is absent.
    func contents() -> (book: Data?, backups: [BackupSlot: Data]) {
        var backups: [BackupSlot: Data] = [:]
        for slot in BackupSlot.allCases {
            backups[slot] = try? Data(contentsOf: backup(slot))
        }
        return (try? Data(contentsOf: book), backups)
    }
}
