import Foundation
import Synchronization
import Testing

@testable import SceneItCore

/// A `LocalFileSystem` that records every call, can fail chosen ones or simulate the process
/// dying at one, and can run an action (another program's write) just before a call.
final class FaultInjectingFileSystem: FileSystem {
    /// One call, naming files relative to the package so traces read like the pipeline. A
    /// hidden temporary file for `book.md` is named "temporary book.md", and one for
    /// `Backups/book-id` "Backups/temporary book-id".
    enum Call: Hashable, CustomStringConvertible {
        case inspect(String)
        case read(String)
        case open(String)
        case writeTemporary(String)
        case publish(String)
        case exchange(String)
        case discard(String)
        case move(String, over: String)
        case createDirectory(String)
        case list(String)
        case remove(String)
        case removeDirectory(String)
        case identify(String)
        /// Creates the lock file if it's missing.
        case lock(String)

        var isMutation: Bool {
            switch self {
            case .inspect, .read, .open, .list, .identify: false
            case .writeTemporary, .publish, .exchange, .discard, .move, .createDirectory, .remove,
                .removeDirectory,
                .lock:
                true
            }
        }

        var description: String {
            switch self {
            case .inspect(let name): "inspect \(name)"
            case .read(let name): "read \(name)"
            case .open(let name): "open \(name)"
            case .writeTemporary(let name): "write a temporary file for \(name)"
            case .publish(let name): "publish \(name)"
            case .exchange(let name): "exchange \(name)"
            case .discard(let name): "discard \(name)"
            case .move(let source, let destination): "move \(source) over \(destination)"
            case .createDirectory(let name): "create directory \(name)"
            case .list(let name): "list \(name)"
            case .remove(let name): "remove \(name)"
            case .removeDirectory(let name): "remove directory \(name)"
            case .identify(let name): "identify \(name)"
            case .lock(let name): "lock \(name)"
            }
        }
    }

    enum Fault {
        /// Every call equal to this one fails with `cause`, until `clearFault()`, except the
        /// first `skipping` such calls after `inject`.
        case fail(Call, cause: FileSystemError.Cause = .io, skipping: Int = 0)
        /// The process dies when it reaches this call: it and every later call do nothing and
        /// fail. A temporary file being written is left half-written.
        case crash(Call)
    }

    private struct State {
        var calls: [Call] = []
        var fault: Fault?
        var crashed = false
        var matched = 0
        var hooks: [(call: Call, action: @Sendable () -> Void)] = []
        var identities: [String: FileIdentity?] = [:]
        var locality: VolumeLocality?
        var enforcement = LockEnforcement.kernel
    }

    private let base = LocalFileSystem()
    private let root: URL
    private let state = Mutex(State())

    init(root: URL) {
        self.root = root
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func inject(_ fault: Fault) {
        state.withLock {
            $0.fault = fault
            $0.matched = 0
        }
    }

    func clearFault() {
        state.withLock { $0.fault = nil }
    }

    func clearCalls() {
        state.withLock { $0.calls = [] }
    }

    /// Runs `action` once, just before the next call equal to `call`.
    func before(_ call: Call, run action: @escaping @Sendable () -> Void) {
        state.withLock { $0.hooks.append((call, action)) }
    }

    func item(at url: URL) throws(FileSystemError) -> FileItem? {
        try perform(.inspect(name(url)), .inspect, url) { () throws(FileSystemError) in try base.item(at: url)
        }
    }

    func read(_ file: URL) throws(FileSystemError) -> Data {
        try perform(.read(name(file)), .read, file) { () throws(FileSystemError) in try base.read(file) }
    }

    func open(_ file: URL) throws(FileSystemError) -> OpenFile {
        try perform(.open(name(file)), .read, file) { () throws(FileSystemError) in try base.open(file) }
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

    func exchange(_ temporary: TemporaryFile, with destination: URL) throws(FileSystemError) {
        try perform(.exchange(name(destination)), .exchange, destination) { () throws(FileSystemError) in
            try base.exchange(temporary, with: destination)
        }
    }

    func discard(_ file: URL) {
        try? perform(.discard(name(file)), .write, file) { () throws(FileSystemError) in base.discard(file) }
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

    func contents(of directory: URL) throws(FileSystemError) -> [DirectoryEntry] {
        try perform(.list(name(directory)), .list, directory) { () throws(FileSystemError) in
            try base.contents(of: directory)
        }
    }

    func remove(_ file: URL) throws(FileSystemError) {
        try perform(.remove(name(file)), .remove, file) { () throws(FileSystemError) in try base.remove(file)
        }
    }

    func removeDirectory(_ directory: URL) throws(FileSystemError) {
        try perform(.removeDirectory(name(directory)), .remove, directory) { () throws(FileSystemError) in
            try base.removeDirectory(directory)
        }
    }

    /// Makes `identity(of: url)` answer `identity` instead of asking the volume.
    func override(identityOf url: URL, with identity: FileIdentity?) {
        let key = name(url)
        state.withLock { $0.identities[key] = .some(identity) }
    }

    func identity(of url: URL) throws(FileSystemError) -> FileIdentity? {
        let key = name(url)
        return try perform(.identify(key), .inspect, url) { () throws(FileSystemError) in
            if let overridden = state.withLock({ $0.identities[key] }) { return overridden }
            return try base.identity(of: url)
        }
    }

    func lock(_ file: URL) -> LockAttempt {
        do {
            try perform(.lock(name(file)), .lock, file) { () throws(FileSystemError) in }
        } catch {
            return .failed(error)
        }
        switch state.withLock({ $0.enforcement }) {
        case .kernel:
            return base.lock(file)
        case .none:
            return ExclusiveFileLock.acquire(file) { _ in
                errno = ENOTSUP
                return -1
            }
        }
    }

    /// `.none` makes every `flock` fail with `ENOTSUP`, as on NFS mounted `nolocks`.
    func override(enforcement: LockEnforcement) {
        state.withLock { $0.enforcement = enforcement }
    }

    /// Makes every volume answer `locality`, such as `.network` on a local test directory.
    func override(locality: VolumeLocality) {
        state.withLock { $0.locality = locality }
    }

    func locality(of url: URL) -> VolumeLocality {
        state.withLock { $0.locality } ?? base.locality(of: url)
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
        let (failure, hook) = state.withLock { state -> (FileSystemError.Cause?, (@Sendable () -> Void)?) in
            state.calls.append(call)
            var hook: (@Sendable () -> Void)?
            if let index = state.hooks.firstIndex(where: { $0.call == call }) {
                hook = state.hooks.remove(at: index).action
            }
            switch state.fault {
            case .fail(call, let cause, let skipping):
                state.matched += 1
                if state.matched > skipping { return (cause, hook) }
            case .crash(call): state.crashed = true
            default: break
            }
            return (state.crashed ? .io : nil, hook)
        }
        hook?()
        if let failure { throw FileSystemError(operation, url, failure) }
        return try body()
    }

    private func name(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        guard path.hasPrefix(rootPath) else { return path }
        let relative = String(path.dropFirst(rootPath.count)).trimmingSlashes
        if let match = relative.wholeMatch(of: /(.*\/)?\.(.+)\.[0-9A-F-]{36}\.tmp/) {
            return "\(match.1 ?? "")temporary \(match.2)"
        }
        return relative
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
                case .typeRegular?: try Data(contentsOf: url)
                case .typeSymbolicLink?:
                    Data(try manager.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false)).utf8)
                default: nil
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
    BookFormat.serialize(book)
}

/// The digest of `draft(number)` as written to disk.
func version(_ number: Int) throws -> ContentDigest {
    ContentDigest(try encoded(draft(number)))
}

/// What a save finds when another program wrote `draft(number)`.
func changed(to number: Int) throws -> SaveError {
    .externallyModified(.changed(theirs: try version(number)))
}

/// "Keep My Version" for the version `draft(number)`.
func overwriting(_ number: Int) throws -> ExternalChangePolicy {
    .overwriteKeepingTheirsAsBackup(theirs: try version(number))
}

extension PackageLayout {
    /// The bytes of `book.md` and each backup slot; `nil` where a file is absent.
    func contents() -> (book: Data?, backups: [BackupSlot: Data]) {
        var backups: [BackupSlot: Data] = [:]
        for slot in BackupSlot.allCases {
            backups[slot] = try? Data(contentsOf: backup(slot))
        }
        return (try? Data(contentsOf: book), backups)
    }
}

extension SaveOutcome {
    /// The backup status of a save that wrote `book.md`; `nil` for `.unchanged`.
    var backupStatus: BackupStatus? {
        if case .saved(let status, _) = self { status } else { nil }
    }

    var published: PublishedBook? {
        if case .saved(_, let published) = self { published } else { nil }
    }
}

extension OpenedBook {
    /// `nil` when the book opened read-only.
    var editable: EditableBook? {
        if case .editing(let editable) = self { editable } else { nil }
    }

    var readOnlyReason: ReadOnlyReason? {
        if case .readOnly(_, let reason) = self { reason } else { nil }
    }
}
