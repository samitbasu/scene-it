import Foundation
import Testing

@testable import SceneItCore

extension LockAttempt {
    /// Consumes the attempt, releasing any lock it took.
    consuming func summary() -> String {
        switch consume self {
        case .acquired: "acquired"
        case .heldElsewhere: "heldElsewhere"
        case .failed(let error): "failed(\(error.cause))"
        }
    }

    consuming func lock() throws -> ExclusiveFileLock {
        switch consume self {
        case .acquired(let lock): return lock
        case .heldElsewhere: throw LockTestFailure.heldElsewhere
        case .failed(let error): throw error
        }
    }
}

private enum LockTestFailure: Error {
    case heldElsewhere
    case noHelper
}

/// Another process that takes the lock on a file and holds it until killed, written in
/// whichever of Python or Perl this Mac has.
private struct LockHolder {
    static let interpreter: (path: String, arguments: [String])? = {
        let python = """
            import fcntl, os, sys, time
            f = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print("busy", flush=True)
                sys.exit(3)
            print("locked", flush=True)
            time.sleep(60)
            """
        let perl = """
            use Fcntl qw(:flock O_RDWR O_CREAT); $| = 1;
            sysopen(my $f, $ARGV[0], O_RDWR | O_CREAT) or die;
            flock($f, LOCK_EX | LOCK_NB) or do { print "busy\\n"; exit 3 };
            print "locked\\n"; sleep 60;
            """
        let candidates = [("/usr/bin/python3", ["-I", "-c", python]), ("/usr/bin/perl", ["-e", perl])]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.0) }.map { ($0.0, $0.1) }
    }()

    let process = Process()
    /// The holder's first line: "locked", or "busy" if it couldn't take the lock.
    let report: String

    init(locking file: URL) throws {
        guard let interpreter = Self.interpreter else { throw LockTestFailure.noHelper }
        process.executableURL = URL(filePath: interpreter.path)
        process.arguments = interpreter.arguments + [file.path(percentEncoded: false)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let line = output.fileHandleForReading.availableData
        report = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func kill() {
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}

@Suite struct ExclusiveFileLockTests {
    @Test func aSecondDescriptorInTheSameProcessFindsTheLockHeld() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "test.lock")
        let first = try ExclusiveFileLock.acquire(file).lock()
        #expect(ExclusiveFileLock.acquire(file).summary() == "heldElsewhere")
        first.release()
        #expect(ExclusiveFileLock.acquire(file).summary() == "acquired")
    }

    @Test(.enabled(if: LockHolder.interpreter != nil, "needs /usr/bin/python3 or /usr/bin/perl"))
    func aKilledHoldersLockIsReleasedByTheKernel() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "test.lock")
        let holder = try LockHolder(locking: file)
        #expect(holder.report == "locked", "precondition: the other process holds the lock")
        #expect(ExclusiveFileLock.acquire(file).summary() == "heldElsewhere")

        holder.kill()
        #expect(holder.process.terminationReason == .uncaughtSignal)
        #expect(ExclusiveFileLock.acquire(file).summary() == "acquired")
    }

    @Test(.enabled(if: LockHolder.interpreter != nil, "needs /usr/bin/python3 or /usr/bin/perl"))
    func anotherProcessCantTakeAHeldLock() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "test.lock")
        let lock = try ExclusiveFileLock.acquire(file).lock()
        let holder = try LockHolder(locking: file)
        holder.process.waitUntilExit()
        #expect(holder.report == "busy")
        lock.release()
    }

    @Test func theDescriptorIsClosedInChildProcesses() throws {
        let directory = try TemporaryDirectory()
        let lock = try ExclusiveFileLock.acquire(directory.url.appending(path: "test.lock")).lock()
        #expect(fcntl(lock.descriptor, F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test func lockingNeverTruncatesOrDeletesTheFile() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "test.lock")
        let contents = Data("someone's record".utf8)
        try contents.write(to: file)
        let lock = try ExclusiveFileLock.acquire(file).lock()
        #expect(try lock.contents() == contents)
        lock.release()
        #expect(try Data(contentsOf: file) == contents)
    }

    @Test func replacingContentsTwiceLeavesOnlyTheLast() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "test.lock")
        let lock = try ExclusiveFileLock.acquire(file).lock()
        try lock.replaceContents(with: Data("a longer first record".utf8))
        try lock.replaceContents(with: Data("short".utf8))
        #expect(try lock.contents() == Data("short".utf8))
        #expect(try Data(contentsOf: file) == Data("short".utf8))
    }

    @Test func aLinkOrPipeAtThePathIsRefused() throws {
        let directory = try TemporaryDirectory()
        let target = directory.url.appending(path: "target")
        try Data().write(to: target)
        let link = directory.url.appending(path: "link.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let pipe = directory.url.appending(path: "pipe.lock")
        #expect(mkfifo(pipe.path(percentEncoded: false), 0o644) == 0)

        #expect(ExclusiveFileLock.acquire(link).summary().hasPrefix("failed"))
        #expect(ExclusiveFileLock.acquire(pipe).summary().hasPrefix("failed"))
    }
}

@Suite struct BookLockTests {
    @Test func aSecondOpenWhileTheFirstIsAliveIsReadOnly() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let first = try BookPackage.create(at: url, title: "Novel").package
            _ = try first.save(draft(1))

            let second = try BookPackage.open(at: url)
            #expect(second.readOnlyReason == .openElsewhere)
            #expect(second.book == (try draft(1)), "a read-only book is still read in full")
            withExtendedLifetime(first) {}

            _ = consume first
            #expect(try BookPackage.open(at: url).editable != nil, "closing the first released the lock")
        }
    }

    @Test func aReadOnlyBookCarriesNoPackageAndSoNoWayToSave() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let holder = try BookPackage.create(at: url, title: "Novel").package
            guard case .readOnly(let readOnly, _) = try BookPackage.open(at: url) else {
                Issue.record("precondition: the second open is read-only")
                return
            }
            withExtendedLifetime(holder) {}
            // `save` is a method of `BookPackage` only, whose initializer is private to the
            // `.editing` path. So a read-only book can't save as long as it holds no package.
            let children = Mirror(reflecting: readOnly).children
            #expect(children.map(\.label) == ["layout", "book"])
            #expect(!children.contains { $0.value is BookPackage })
        }
    }

    @Test func aFolderWithoutWritePermissionOpensReadOnly() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            do {
                let package = try BookPackage.create(at: url, title: "Novel").package
                _ = consume package
            }
            try FileManager.default.removeItem(at: url.layout.lock)
            #expect(chmod(url.path(percentEncoded: false), 0o555) == 0)
            defer { chmod(url.path(percentEncoded: false), 0o755) }

            let opened = try BookPackage.open(at: url)
            #expect(
                opened.readOnlyReason
                    == .lockUnavailable(FileSystemError(.lock, url.layout.lock, .permissionDenied)))
        }
    }

    @Test func aBookThatFailsToLoadGainsNoLockFile() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            #expect(throws: LoadError.self) { try BookPackage.open(at: url) }
            #expect(!FileManager.default.fileExists(atPath: url.layout.lock.path(percentEncoded: false)))
        }
    }

    @Test func theLockFileIsNeverListedAsABackup() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            do {
                let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
                _ = consume package
            }
            try Data("{}".utf8).write(to: url.layout.book)
            #expect(FileManager.default.fileExists(atPath: url.layout.lock.path(percentEncoded: false)))
            let error = try #require(throws: LoadError.self) { try BookPackage.open(at: url) }
            #expect(error.backups.map(\.slot) == BackupSlot.allCases)
        }
    }

    @Test func anInjectedLockFailureOpensReadOnlyAndCreateFails() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            fileSystem.inject(.fail(.lock(".lock"), cause: .readOnlyVolume))
            let failure = FileSystemError(.lock, url.layout.lock, .readOnlyVolume)
            #expect(throws: CreateError.fileSystem(failure)) {
                try BookPackage.create(at: url, title: "Novel", fileSystem: fileSystem)
            }
            #expect(!FileManager.default.fileExists(atPath: url.layout.book.path(percentEncoded: false)))

            try FileManager.default.removeItem(at: url)
            do {
                let package = try BookPackage.create(at: url, title: "Novel").package
                _ = consume package
            }
            #expect(
                try BookPackage.open(at: url, fileSystem: fileSystem).readOnlyReason
                    == .lockUnavailable(failure))
        }
    }
}

/// The advisory record on network volumes, with `FaultInjectingFileSystem` calling a local
/// test directory a network volume.
@Suite struct NetworkLockTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let thisMac = ThisMac(name: "Desk", id: "MAC-A")

    private func record(host: String = "Laptop", id: String = "MAC-B", age: Interval) -> LockRecord {
        LockRecord(host: host, hostID: id, processID: 42, since: now - age)
    }

    private func blocking(_ record: LockRecord?, policy: OtherMacPolicy = .respect) -> LockRecord? {
        LockRecord.blocking(record, thisMac: thisMac, now: now, policy: policy)
    }

    @Test func onlyAFreshRecordFromAnotherMacBlocks() {
        let fresh = record(age: .hours(1))
        #expect(blocking(nil) == nil)
        #expect(blocking(fresh) == fresh)
        #expect(blocking(record(age: .hours(12) - .seconds(1))) != nil)
        #expect(blocking(record(age: .hours(12))) == nil, "stale at exactly staleAfter")
        #expect(blocking(record(age: .days(3))) == nil)
        #expect(blocking(record(host: "Desk", id: "MAC-A", age: .zero)) == nil, "this Mac's leftover")
        #expect(blocking(record(host: "Desk", id: "MAC-B", age: .zero)) != nil, "same name, another Mac")
        let future = LockRecord(host: "Laptop", hostID: "MAC-B", processID: 42, since: now + .hours(1))
        #expect(blocking(future) == future, "a clock ahead of ours doesn't make a record stale")
    }

    @Test func openAnywayOverridesOnlyTheRecordTheWriterSaw() {
        let seen = record(age: .hours(1))
        let newer = record(age: .minutes(1))
        #expect(blocking(seen, policy: .openAnyway(seen)) == nil)
        #expect(blocking(newer, policy: .openAnyway(seen)) == newer)
    }

    @Test func aRecordSurvivesItsEncodingAndJunkIsNoRecord() throws {
        let original = record(age: .hours(1))
        #expect(LockRecord.decode(try original.encoded()) == original)
        #expect(LockRecord.decode(Data()) == nil)
        #expect(LockRecord.decode(Data("{\"title\":\"My Novel\"}".utf8)) == nil)
    }

    private func networkPackage(_ directory: URL) throws -> (URL, FaultInjectingFileSystem) {
        let url = directory.appending(path: "Novel.sceneit")
        let fileSystem = FaultInjectingFileSystem(root: url)
        fileSystem.override(locality: .network)
        do {
            let package = try BookPackage.create(at: url, title: "Novel", fileSystem: fileSystem).package
            _ = consume package
        }
        return (url, fileSystem)
    }

    @Test func editingOnANetworkVolumeRecordsThisMacUntilClosed() throws {
        try withTemporaryDirectory { directory in
            let (url, fileSystem) = try networkPackage(directory)
            #expect(try Data(contentsOf: url.layout.lock).isEmpty, "create's record was cleared on close")
            let package = try #require(BookPackage.open(at: url, fileSystem: fileSystem).editable).package
            let written = try #require(LockRecord.decode(Data(contentsOf: url.layout.lock)))
            #expect(written.hostID == ThisMac.current.id)
            #expect(written.processID == getpid())
            _ = consume package
            #expect(try Data(contentsOf: url.layout.lock).isEmpty)
        }
    }

    @Test func anotherMacsRecordOpensReadOnlyUntilOpenAnyway() throws {
        try withTemporaryDirectory { directory in
            let (url, fileSystem) = try networkPackage(directory)
            let theirs = LockRecord(
                host: "Laptop", hostID: "another Mac", processID: 42, since: .now - .minutes(5))
            let theirBytes = try theirs.encoded()
            try theirBytes.write(to: url.layout.lock)

            let opened = try BookPackage.open(at: url, fileSystem: fileSystem)
            #expect(opened.readOnlyReason == .openOnAnotherMac(LockRecord.decode(theirBytes)!))
            #expect(try Data(contentsOf: url.layout.lock) == theirBytes, "their record is left alone")
            #expect(ExclusiveFileLock.acquire(url.layout.lock).summary() == "acquired", "no lock kept")

            let seen = try #require(LockRecord.decode(theirBytes))
            let anyway = try #require(
                BookPackage.open(at: url, onAnotherMac: .openAnyway(seen), fileSystem: fileSystem).editable)
            #expect(try LockRecord.decode(Data(contentsOf: url.layout.lock))?.hostID == ThisMac.current.id)
            withExtendedLifetime(anyway) {}
        }
    }

    @Test func aRecordLeftByThisMacIsIgnored() throws {
        try withTemporaryDirectory { directory in
            let (url, fileSystem) = try networkPackage(directory)
            let leftover = LockRecord(ThisMac.current, processID: 1, since: .now - .minutes(5))
            try leftover.encoded().write(to: url.layout.lock)
            #expect(try BookPackage.open(at: url, fileSystem: fileSystem).editable != nil)
        }
    }

    @Test func closingLeavesAnotherMacsRecordAlone() throws {
        try withTemporaryDirectory { directory in
            let (url, fileSystem) = try networkPackage(directory)
            let package = try #require(BookPackage.open(at: url, fileSystem: fileSystem).editable).package
            let theirs = try LockRecord(host: "Laptop", hostID: "another Mac", processID: 42, since: .now)
                .encoded()
            try theirs.write(to: url.layout.lock)
            _ = consume package
            #expect(try Data(contentsOf: url.layout.lock) == theirs)
        }
    }
}
