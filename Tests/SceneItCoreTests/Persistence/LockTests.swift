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

    @Test func aLockFileWithoutWritePermissionIsLockedReadOnly() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            do {
                let package = try BookPackage.create(at: url, title: "Novel").package
                _ = consume package
            }
            let lockPath = url.layout.lock.path(percentEncoded: false)
            #expect(chmod(lockPath, 0o444) == 0)
            #expect(open(lockPath, O_RDWR) == -1 && errno == EACCES, "precondition: not writable")

            let package = try #require(BookPackage.open(at: url).editable).package
            #expect(try BookPackage.open(at: url).readOnlyReason == .openElsewhere, "the flock is real")
            #expect(try package.save(draft(1)).backupStatus == .intact)
        }
    }

    @Test func aReadOnlyLockFileOnANetworkVolumeEditsWithoutARecord() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            do {
                let package = try BookPackage.create(at: url, title: "Novel").package
                _ = consume package
            }
            #expect(chmod(url.layout.lock.path(percentEncoded: false), 0o444) == 0)
            let fileSystem = FaultInjectingFileSystem(root: url)
            fileSystem.override(locality: .network)
            let opened = try BookPackage.open(at: url, fileSystem: fileSystem)
            #expect(opened.editable != nil, "the record can't be written, which is logged, not fatal")
            #expect(try Data(contentsOf: url.layout.lock).isEmpty)
        }
    }

    @Test func aBookChangedWhileItWasBeingLockedIsReadAgain() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            do {
                let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
                _ = consume package
            }
            let fileSystem = FaultInjectingFileSystem(root: url)
            fileSystem.before(.lock(".lock")) { try? encoded(draft(7)).write(to: url.layout.book) }
            let opened = try #require(BookPackage.open(at: url, fileSystem: fileSystem).editable)
            #expect(opened.book == (try draft(7)))
            #expect(try opened.package.save(draft(9)).backupStatus == .intact, "lastSeen is the new version")
        }
    }

    @Test func aBookDamagedWhileItWasBeingLockedFailsAndReleasesTheLock() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            do {
                let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
                _ = consume package
            }
            let fileSystem = FaultInjectingFileSystem(root: url)
            fileSystem.before(.lock(".lock")) { try? Data("{".utf8).write(to: url.layout.book) }
            let error = try #require(throws: LoadError.self) {
                try BookPackage.open(at: url, fileSystem: fileSystem)
            }
            guard case .undecodable = error.problem else {
                Issue.record("expected undecodable, got \(error.problem)")
                return
            }
            #expect(ExclusiveFileLock.acquire(url.layout.lock).summary() == "acquired")
        }
    }
}

/// The advisory record, where the `flock` can't be trusted: `FaultInjectingFileSystem` calls a
/// local test directory a network volume, or a volume without `flock`.
@Suite struct LockRecordTests {
    private static let desk = ThisMac(name: "Desk", id: "MAC-A")
    private static let livePeer: Int32 = 600
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let opener = Opener(
        mac: desk, userID: 501, processID: 500, isAlive: { $0 == 500 || $0 == livePeer })

    private func record(id: String = "MAC-B", processID: Int32 = 42) -> LockRecord {
        LockRecord(host: "Laptop", hostID: id, userID: 502, processID: processID, since: now - .days(30))
    }

    private func blocking(_ record: LockRecord?, policy: LockRecordPolicy = .respect) -> LockRecord? {
        LockRecord.blocking(record, opener: opener, policy: policy)
    }

    @Test func anotherMacsRecordBlocksHoweverOldItIs() {
        let old = record()
        #expect(blocking(nil) == nil)
        #expect(blocking(old) == old, "a live writer's record never expires")
        let sameName = LockRecord(host: "Desk", hostID: "MAC-B", userID: 501, processID: 500, since: now)
        #expect(blocking(sameName) == sameName, "same name, another Mac")
    }

    @Test func aRecordFromThisMacBlocksOnlyWhileItsProcessLives() {
        let live = record(id: "MAC-A", processID: Self.livePeer)
        #expect(blocking(live) == live)
        #expect(blocking(record(id: "MAC-A", processID: 77)) == nil, "a dead process's leftover")
        #expect(blocking(record(id: "MAC-A", processID: 500)) == nil, "the opener's own")
    }

    @Test func liveProcessesIncludeOtherUsers() throws {
        #expect(Opener.processIsAlive(getpid()))
        #expect(Opener.processIsAlive(1), "launchd is root's: EPERM still means alive")
        let finished = Process()
        finished.executableURL = URL(filePath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        #expect(!Opener.processIsAlive(finished.processIdentifier))
    }

    @Test func openAnywayOverridesOnlyTheRecordTheWriterSaw() {
        let seen = record()
        let newer = record(processID: 43)
        #expect(blocking(seen, policy: .openAnyway(seen)) == nil)
        #expect(blocking(newer, policy: .openAnyway(seen)) == newer)
    }

    @Test func aRecordSurvivesItsEncodingAndJunkIsNoRecord() throws {
        let original = record()
        #expect(LockRecord.decode(try original.encoded()) == original)
        #expect(LockRecord.decode(Data()) == nil)
        #expect(LockRecord.decode(Data("{\"title\":\"My Novel\"}".utf8)) == nil)
    }

    enum Untrusted: CaseIterable {
        case network, noFlock
    }

    private func untrustedPackage(_ directory: URL, _ untrusted: Untrusted) throws -> (
        URL, FaultInjectingFileSystem
    ) {
        let url = directory.appending(path: "Novel.sceneit")
        let fileSystem = FaultInjectingFileSystem(root: url)
        switch untrusted {
        case .network: fileSystem.override(locality: .network)
        case .noFlock: fileSystem.override(enforcement: .none)
        }
        do {
            let package = try BookPackage.create(
                at: url, title: "Novel", fileSystem: fileSystem, opener: opener
            ).package
            _ = consume package
        }
        return (url, fileSystem)
    }

    private func open(
        _ url: URL, _ fileSystem: FaultInjectingFileSystem, as other: Opener? = nil,
        policy: LockRecordPolicy = .respect
    ) throws -> OpenedBook {
        try BookPackage.open(at: url, onLockRecord: policy, fileSystem: fileSystem, opener: other ?? opener)
    }

    @Test(arguments: Untrusted.allCases)
    func editingRecordsTheOpenerUntilClosed(_ untrusted: Untrusted) throws {
        try withTemporaryDirectory { directory in
            let (url, fileSystem) = try untrustedPackage(directory, untrusted)
            #expect(try Data(contentsOf: url.layout.lock).isEmpty, "create's record was cleared on close")
            let package = try #require(open(url, fileSystem).editable).package
            let written = try #require(LockRecord.decode(Data(contentsOf: url.layout.lock)))
            #expect(written.hostID == "MAC-A")
            #expect(written.userID == 501)
            #expect(written.processID == 500)
            _ = consume package
            #expect(try Data(contentsOf: url.layout.lock).isEmpty)
        }
    }

    @Test(arguments: Untrusted.allCases)
    func anotherMacsRecordOpensReadOnlyUntilOpenAnyway(_ untrusted: Untrusted) throws {
        try withTemporaryDirectory { directory in
            let (url, fileSystem) = try untrustedPackage(directory, untrusted)
            let theirs = record()
            try theirs.encoded().write(to: url.layout.lock)

            #expect(try open(url, fileSystem).readOnlyReason == .openOnAnotherMac(theirs))
            #expect(try LockRecord.decode(Data(contentsOf: url.layout.lock)) == theirs, "left alone")
            #expect(ExclusiveFileLock.acquire(url.layout.lock).summary() == "acquired", "no lock kept")

            let anyway = try #require(open(url, fileSystem, policy: .openAnyway(theirs)).editable)
            #expect(try LockRecord.decode(Data(contentsOf: url.layout.lock))?.hostID == "MAC-A")
            withExtendedLifetime(anyway) {}
        }
    }

    @Test func withoutFlockALiveProcessOnThisMacKeepsOthersOut() throws {
        try withTemporaryDirectory { directory in
            let (url, fileSystem) = try untrustedPackage(directory, .noFlock)
            let first = try #require(open(url, fileSystem).editable).package
            let peer = Opener(mac: Self.desk, userID: 502, processID: Self.livePeer, isAlive: opener.isAlive)
            let second = try open(url, fileSystem, as: peer)
            guard case .openInAnotherProcess(let holder)? = second.readOnlyReason else {
                Issue.record(
                    "expected openInAnotherProcess, got \(String(describing: second.readOnlyReason))")
                return
            }
            #expect(holder.processID == 500)
            withExtendedLifetime(first) {}
        }
    }

    @Test func aRecordLeftByADeadProcessOnThisMacIsIgnored() throws {
        try withTemporaryDirectory { directory in
            let (url, fileSystem) = try untrustedPackage(directory, .network)
            try record(id: "MAC-A", processID: 77).encoded().write(to: url.layout.lock)
            #expect(try open(url, fileSystem).editable != nil)
        }
    }

    @Test func closingLeavesAnotherMacsRecordAlone() throws {
        try withTemporaryDirectory { directory in
            let (url, fileSystem) = try untrustedPackage(directory, .network)
            let package = try #require(open(url, fileSystem).editable).package
            let theirs = try record().encoded()
            try theirs.write(to: url.layout.lock)
            _ = consume package
            #expect(try Data(contentsOf: url.layout.lock) == theirs)
        }
    }
}
