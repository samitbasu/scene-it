import Foundation
import Synchronization
import Testing

@testable import SceneItCore

/// A `LocalFileSystem` that records every call and can fail chosen ones.
final class FaultInjectingFileSystem: FileSystem {
    /// One call, naming files relative to the package so traces read like the pipeline.
    enum Call: Hashable, CustomStringConvertible {
        case inspect(String)
        case read(String)
        case write(String)
        case move(String, over: String)
        case createDirectory(String)

        var isMutation: Bool {
            switch self {
            case .inspect, .read: false
            case .write, .move, .createDirectory: true
            }
        }

        var description: String {
            switch self {
            case .inspect(let name): "inspect \(name)"
            case .read(let name): "read \(name)"
            case .write(let name): "write \(name)"
            case .move(let source, let destination): "move \(source) over \(destination)"
            case .createDirectory(let name): "create directory \(name)"
            }
        }
    }

    /// What a faulted write leaves behind.
    enum Debris {
        case none
        /// A half-written temporary file next to the target, as a crash mid-write would leave.
        case partialTemporaryFile
    }

    private struct State {
        var calls: [Call] = []
        var fault: Call?
        var debris = Debris.none
    }

    private let base = LocalFileSystem()
    private let root: URL
    private let state = Mutex(State())

    init(root: URL) {
        self.root = root
    }

    var calls: [Call] { state.withLock { $0.calls } }

    /// Every later call equal to `call` fails, until `clearFault()`.
    func inject(_ call: Call, leaving debris: Debris = .none) {
        state.withLock {
            $0.fault = call
            $0.debris = debris
        }
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

    func writeAtomically(_ data: Data, to file: URL) throws(FileSystemError) -> FileStamp {
        try perform(.write(name(file)), .write, file, partialData: data) { () throws(FileSystemError) in
            try base.writeAtomically(data, to: file)
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

    private func perform<T>(
        _ call: Call, _ operation: FileSystemError.Operation, _ url: URL, partialData: Data? = nil,
        _ body: () throws(FileSystemError) -> T
    ) throws(FileSystemError) -> T {
        let (fault, debris) = state.withLock { state in
            state.calls.append(call)
            return (state.fault, state.debris)
        }
        guard call == fault else { return try body() }
        if case .partialTemporaryFile = debris, let partialData {
            let temporary = url.deletingLastPathComponent()
                .appending(path: ".\(url.lastPathComponent).crashed.tmp")
            try? partialData.prefix(partialData.count / 2).write(to: temporary)
        }
        throw FileSystemError(operation, url, .other("injected fault"))
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
            let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
            entries[path] = Entry(
                contents: isDirectory ? nil : try Data(contentsOf: url),
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
