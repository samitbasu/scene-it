import Foundation
import Testing

@testable import SceneItCore

/// Monday 2 November 2026, 09:00 UTC.
private let start = Date(timeIntervalSince1970: 1_793_610_000)

/// A book package and a mirror root (standing in for Application Support) in one temporary
/// directory, on a file system that can fail chosen calls.
struct KeeperFixture {
    let directory: URL
    let fileSystem: FaultInjectingFileSystem
    let mirror: BackupMirror
    /// `nil` only inside `switchTo`, between closing one book and opening the next.
    private var open: BookPackage?
    var keeper: BackupKeeper

    init(_ directory: URL, mirrorRoot: String = "Application Support/Scene It/Backups") throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory.appending(path: "Application Support"), withIntermediateDirectories: false)
        fileSystem = FaultInjectingFileSystem(root: directory)
        mirror = BackupMirror(root: directory.appending(path: mirrorRoot, directoryHint: .isDirectory))
        let package = try BookPackage.create(
            at: directory.appending(path: "Novel.sceneit"), title: "Novel", fileSystem: fileSystem
        ).package
        open = package
        keeper = BackupKeeper(package: package, mirror: mirror)
    }

    var package: BookPackage { open! }
    var layout: PackageLayout { package.layout }

    /// Closes this book and opens another with the same mirror, as the store would. Closing
    /// first releases the lock, which a moved package still holds.
    mutating func switchTo(_ url: URL) throws {
        open = nil
        let package = try #require(BookPackage.open(at: url, fileSystem: fileSystem).editable).package
        open = package
        keeper = BackupKeeper(package: package, mirror: mirror)
    }

    /// Saves `book` and keeps snapshots at `now`, the way the store does.
    @discardableResult
    func save(_ book: Book, at now: Date) throws -> SnapshotReport {
        let outcome = try package.save(book)
        #expect(outcome.backupStatus == .intact)
        return keeper.keep(try #require(outcome.published), now: now)
    }

    func bookID() throws -> UUID {
        let text = try String(contentsOf: layout.bookID, encoding: .utf8)
        return try #require(UUID(uuidString: text.trimmingCharacters(in: .newlines)))
    }

    func mirrorFolder() throws -> URL { mirror.folder(for: try bookID()) }

    func mirrorFolders() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: mirror.root.path(percentEncoded: false)))
    }

    func record(in folder: URL) throws -> PackageRecord {
        try JSONDecoder().decode(
            PackageRecord.self, from: Data(contentsOf: BackupMirror.packageRecord(in: folder)))
    }

    /// The snapshot names in `folder`, oldest first.
    func snapshots(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { SnapshotName(fileName: $0) != nil }.sorted()
    }

    func relative(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let root = directory.standardizedFileURL.path(percentEncoded: false)
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private func snapshotName(_ date: Date) throws -> String {
    try #require(SnapshotName(date: date)).fileName
}

private let bothWritten = SnapshotReport(package: .written, mirror: .written)

@Suite struct BackupKeeperTests {
    @Test func theFirstSaveSnapshotsThePublishedBytesInBothPlaces() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            #expect(try fixture.save(draft(1), at: start) == bothWritten)

            let published = try Data(contentsOf: fixture.layout.book)
            let name = try snapshotName(start)
            #expect(try Data(contentsOf: fixture.layout.snapshots.appending(path: name)) == published)
            #expect(try Data(contentsOf: fixture.mirrorFolder().appending(path: name)) == published)
            let record = try fixture.record(in: fixture.mirrorFolder())
            #expect(record.path == BackupMirror.path(of: fixture.layout.root))
            #expect(record.identity != nil, "precondition: the temporary volume has a UUID")
            #expect(try temporaryFiles(in: fixture.layout.snapshots).isEmpty)
        }
    }

    @Test func theLockFileIsNeverSnapshottedOrMirrored() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            let lockFile = fixture.layout.lock
            #expect(
                FileManager.default.fileExists(atPath: lockFile.path(percentEncoded: false)), "precondition")
            #expect(try fixture.save(draft(1), at: start) == bothWritten)

            let published = try Data(contentsOf: fixture.layout.book)
            for folder in [fixture.layout.snapshots, try fixture.mirrorFolder()] {
                let names = try FileManager.default.contentsOfDirectory(
                    atPath: folder.path(percentEncoded: false))
                #expect(!names.contains(".lock"))
                for name in try fixture.snapshots(in: folder) {
                    #expect(try Data(contentsOf: folder.appending(path: name)) == published)
                }
            }
            let archive = try FileManager.default.contentsOfDirectory(
                atPath: fixture.layout.archive.path(percentEncoded: false))
            #expect(archive == ["index.json"])
        }
    }

    @Test func snapshotsFollowTheCadence() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            #expect(
                try fixture.save(draft(2), at: start + .minutes(9))
                    == SnapshotReport(package: .notDue, mirror: .notDue))
            #expect(try fixture.save(draft(3), at: start + .minutes(10)) == bothWritten)
            #expect(
                try fixture.snapshots(in: fixture.layout.snapshots) == [
                    try snapshotName(start), try snapshotName(start + .minutes(10)),
                ])
        }
    }

    /// Two hours of saves every 10 minutes, every day for a week.
    @Test func aWeekOfSavesKeepsTheTiers() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            let drafts = [try draft(1), try draft(2)]
            var now = start
            for day in 0..<7 {
                for slot in 0..<12 {
                    now = start + .days(day) + .minutes(10 * slot)
                    #expect(try fixture.save(drafts[slot % 2], at: now) == bothWritten)
                }
            }
            let kept = try fixture.snapshots(in: fixture.layout.snapshots)
            #expect(try fixture.snapshots(in: fixture.mirrorFolder()) == kept)

            let dates = kept.compactMap { SnapshotName(fileName: $0)?.date }
            let lastDay = dates.filter { $0 > now - .hours(24) }
            #expect(lastDay.count == 12, "one every 10 minutes of the last session")
            for (earlier, later) in zip(lastDay, lastDay.dropFirst()) {
                #expect(later.timeIntervalSince(earlier) == 600)
            }
            let olderDays = dates.filter { $0 <= now - .hours(24) }
            // The day before's last window ends less than 24 h ago, so it's still fine-grained.
            let lastWindowOfTheDayBefore = start + .days(5) + .minutes(110)
            #expect(
                olderDays == (0..<6).map { start + .days($0) } + [lastWindowOfTheDayBefore],
                "the first snapshot of each earlier day")
        }
    }

    @Test func theMirrorSurvivesDeletingThePackage() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let published = try Data(contentsOf: fixture.layout.book)
            let folder = try fixture.mirrorFolder()
            try FileManager.default.removeItem(at: fixture.layout.root)
            #expect(try Data(contentsOf: folder.appending(path: snapshotName(start))) == published)
        }
    }

    @Test func aCopiedPackageForksItsID() throws {
        try withTemporaryDirectory { directory in
            var fixture = try KeeperFixture(directory)
            let original = fixture.layout.root
            try fixture.save(draft(1), at: start)
            let originalID = try fixture.bookID()

            let copy = directory.appending(path: "Novel copy.sceneit")
            try FileManager.default.copyItem(at: original, to: copy)
            try fixture.switchTo(copy)
            #expect(try fixture.bookID() == originalID, "precondition: the copy carries the original's id")
            #expect(try fixture.save(draft(2), at: start + .minutes(10)) == bothWritten)
            let copyID = try fixture.bookID()
            #expect(copyID != originalID)
            #expect(try fixture.mirrorFolders() == [originalID.uuidString, copyID.uuidString])
            #expect(
                try fixture.snapshots(in: fixture.mirrorFolder()) == [try snapshotName(start + .minutes(10))])

            try fixture.switchTo(original)
            try fixture.save(draft(3), at: start + .minutes(20))
            #expect(try fixture.bookID() == originalID, "the original keeps its id")
            #expect(
                try fixture.snapshots(in: fixture.mirrorFolder()) == [
                    try snapshotName(start), try snapshotName(start + .minutes(20)),
                ])
            #expect(try fixture.mirrorFolders().count == 2)
        }
    }

    /// A moved package is recognized by its identity, without looking at its old path.
    @Test func aMovedPackageKeepsItsIDAndFolder() throws {
        try withTemporaryDirectory { directory in
            var fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let id = try fixture.bookID()
            let oldPath = fixture.layout.root
            let moved = directory.appending(path: "Renamed.sceneit")
            try FileManager.default.moveItem(at: oldPath, to: moved)
            try FileManager.default.createDirectory(at: oldPath, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: PackageLayout(root: oldPath).snapshots, withIntermediateDirectories: false)
            try Data(id.uuidString.utf8).write(to: PackageLayout(root: oldPath).bookID)

            try fixture.switchTo(moved)
            fixture.fileSystem.clearCalls()
            try fixture.save(draft(2), at: start + .minutes(10))
            #expect(try fixture.bookID() == id, "not forked, though the old path holds the same id")
            #expect(try fixture.mirrorFolders() == [id.uuidString])
            #expect(try fixture.record(in: fixture.mirrorFolder()).path == BackupMirror.path(of: moved))
            #expect(try fixture.snapshots(in: fixture.mirrorFolder()).count == 2)
            let probe = FaultInjectingFileSystem.Call.read(
                fixture.relative(PackageLayout(root: oldPath).bookID))
            #expect(!fixture.fileSystem.calls.contains(probe))
        }
    }

    /// A drive cloned file by file and mounted under the same name: the same path, but a
    /// different directory.
    @Test func anotherDirectoryAtTheSamePathForks() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let id = try fixture.bookID()
            let recorded = try #require(try fixture.record(in: fixture.mirrorFolder()).identity)

            let clone = FileIdentity(volume: UUID().uuidString, file: recorded.file)
            fixture.fileSystem.override(identityOf: fixture.layout.root, with: clone)
            #expect(try fixture.save(draft(2), at: start + .minutes(10)) == bothWritten)
            let newID = try fixture.bookID()
            #expect(newID != id)
            #expect(try fixture.record(in: fixture.mirror.folder(for: newID)).identity == clone)
            #expect(try fixture.snapshots(in: fixture.mirror.folder(for: id)) == [try snapshotName(start)])
        }
    }

    @Test func withoutIdentitiesThePathDecides() throws {
        try withTemporaryDirectory { directory in
            var fixture = try KeeperFixture(directory)
            fixture.fileSystem.override(identityOf: fixture.layout.root, with: nil)
            try fixture.save(draft(1), at: start)
            let id = try fixture.bookID()
            #expect(try fixture.record(in: fixture.mirrorFolder()).identity == nil)
            try fixture.save(draft(2), at: start + .minutes(10))
            #expect(try fixture.bookID() == id)

            let copy = directory.appending(path: "Novel copy.sceneit")
            try FileManager.default.copyItem(at: fixture.layout.root, to: copy)
            try fixture.switchTo(copy)
            fixture.fileSystem.override(identityOf: copy, with: nil)
            try fixture.save(draft(3), at: start + .minutes(20))
            #expect(try fixture.bookID() != id, "the copy is found by reading the recorded path")
        }
    }

    @Test func aCopyWhoseOriginalIsGoneTakesOverTheFolder() throws {
        try withTemporaryDirectory { directory in
            var fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let id = try fixture.bookID()
            let copy = directory.appending(path: "Novel copy.sceneit")
            try FileManager.default.copyItem(at: fixture.layout.root, to: copy)
            try FileManager.default.removeItem(at: fixture.layout.root)
            try fixture.switchTo(copy)
            try fixture.save(draft(2), at: start + .minutes(10))
            #expect(try fixture.bookID() == id)
            #expect(try fixture.mirrorFolders() == [id.uuidString])
        }
    }

    @Test(arguments: [Data("not a uuid\n".utf8), Data(), Data([0xFF, 0xFE])])
    func aCorruptIDStartsANewFolderAndKeepsTheOld(_ corrupt: Data) throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let oldID = try fixture.bookID()
            try corrupt.write(to: fixture.layout.bookID)
            #expect(try fixture.save(draft(2), at: start + .minutes(10)) == bothWritten)
            let newID = try fixture.bookID()
            #expect(newID != oldID)
            #expect(try fixture.mirrorFolders() == [oldID.uuidString, newID.uuidString])
            #expect(try fixture.snapshots(in: fixture.mirror.folder(for: oldID)) == [try snapshotName(start)])
        }
    }

    @Test func aCorruptRecordForks() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let id = try fixture.bookID()
            try Data("/not/json".utf8).write(to: BackupMirror.packageRecord(in: fixture.mirrorFolder()))
            #expect(try fixture.save(draft(2), at: start + .minutes(10)) == bothWritten)
            #expect(try fixture.bookID() != id)
        }
    }

    @Test func anUnreadableIDIsReportedAndLeftAlone() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let before = try Data(contentsOf: fixture.layout.bookID)
            fixture.fileSystem.inject(
                .fail(.read(fixture.relative(fixture.layout.bookID)), cause: .permissionDenied))
            let report = try fixture.save(draft(2), at: start + .minutes(10))
            #expect(report.package == .written)
            guard case .failed(.fileSystem(.readBookID, let error)) = report.mirror else {
                Issue.record("unexpected report \(report)")
                return
            }
            #expect(error.cause == .permissionDenied)
            #expect(try Data(contentsOf: fixture.layout.bookID) == before)
            #expect(try fixture.mirrorFolders().count == 1)
        }
    }

    /// Two keepers racing to the same snapshot name: the loser finds what it wanted.
    @Test func aSnapshotThatAppearsWithTheSameBytesCountsAsWritten() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let now = start + .minutes(10)
            let snapshot = fixture.layout.snapshots.appending(path: try snapshotName(now))
            let outcome = try fixture.package.save(draft(2))
            let bytes = try Data(contentsOf: fixture.layout.book)
            fixture.fileSystem.before(.publish(fixture.relative(snapshot))) { try? bytes.write(to: snapshot) }
            #expect(fixture.keeper.keep(try #require(outcome.published), now: now) == bothWritten)

            let later = start + .minutes(20)
            let other = fixture.layout.snapshots.appending(path: try snapshotName(later))
            let next = try fixture.package.save(draft(3))
            fixture.fileSystem.before(.publish(fixture.relative(other))) {
                try? Data("other".utf8).write(to: other)
            }
            let report = fixture.keeper.keep(try #require(next.published), now: later)
            guard case .failed(.fileSystem(.write, let error)) = report.package else {
                Issue.record("unexpected report \(report)")
                return
            }
            #expect(error.cause == .alreadyExists)
            #expect(try Data(contentsOf: other) == Data("other".utf8))
        }
    }

    /// Nothing is read, written or pruned through the link: not snapshots, not `book-id`.
    @Test func aSymlinkedBackupsFolderIsRefusedByBothDestinations() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            let outside = directory.appending(path: "Outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let names = [try snapshotName(start - .days(5)), try snapshotName(start - .days(5) + .hours(1))]
            for name in names { try Data(name.utf8).write(to: outside.appending(path: name)) }
            try Data("not a uuid".utf8).write(to: outside.appending(path: "book-id"))
            try FileManager.default.removeItem(at: fixture.layout.snapshots)
            try FileManager.default.createSymbolicLink(
                at: fixture.layout.snapshots, withDestinationURL: outside)
            let before = try DirectorySnapshot(outside)

            let report = try fixture.save(draft(1), at: start)
            #expect(
                report == SnapshotReport(package: .failed(.notARealFolder), mirror: .failed(.notARealFolder)))
            #expect(try DirectorySnapshot(outside) == before)
            #expect(!FileManager.default.fileExists(atPath: fixture.mirror.root.path(percentEncoded: false)))
        }
    }

    @Test func aBackupsFolderLinkedToAnotherBookLeavesThatBookAlone() throws {
        try withTemporaryDirectory { directory in
            var fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let other = fixture.layout
            let otherBefore = try DirectorySnapshot(other.snapshots)
            let foldersBefore = try fixture.mirrorFolders()

            let second = directory.appending(path: "Second.sceneit")
            _ = try BookPackage.create(at: second, title: "Second")
            let secondLayout = PackageLayout(root: second)
            try FileManager.default.removeItem(at: secondLayout.snapshots)
            try FileManager.default.createSymbolicLink(
                at: secondLayout.snapshots, withDestinationURL: other.snapshots)
            try fixture.switchTo(second)

            let report = try fixture.save(draft(2), at: start + .minutes(10))
            #expect(
                report == SnapshotReport(package: .failed(.notARealFolder), mirror: .failed(.notARealFolder)))
            #expect(
                try DirectorySnapshot(other.snapshots) == otherBefore, "the other book's id and snapshots")
            #expect(try fixture.mirrorFolders() == foldersBefore)
        }
    }

    @Test func aSymlinkedMirrorFolderIsRefused() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let folder = try fixture.mirrorFolder()
            let outside = directory.appending(path: "Outside")
            try FileManager.default.moveItem(at: folder, to: outside)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
            let before = try DirectorySnapshot(outside)

            let report = try fixture.save(draft(2), at: start + .minutes(10))
            #expect(report == SnapshotReport(package: .written, mirror: .failed(.notARealFolder)))
            #expect(try DirectorySnapshot(outside) == before)
        }
    }

    @Test func pruningNeverTouchesFilesThatAreNotExactlySnapshots() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let oldDay = start - .days(5)
            let redundant = try snapshotName(oldDay + .hours(1))
            let outsideFile = directory.appending(path: "outside.txt")
            try Data("outside".utf8).write(to: outsideFile)
            let decoys = [
                "notes.txt", "book-20261028T090000Z.json.bak", "book-20261028T100000Z.JSON",
                "Book-20261028T113000Z.json", "book-2026-10-28T12:00:00Z.json", "book-20261028T1300Z.json",
                ".book-20261028T140000Z.json.tmp", "book-20261028T150000Z.json~",
                "book-20261028T150000Z.json ",
                "book-٢٠٢٦١٠٢٨T090000Z.json", "book-２０２６1028T090000Z.json", "book-20261028t093400Z.json",
                "book-20270229T000000Z.json",
            ]
            let manager = FileManager.default
            for folder in [fixture.layout.snapshots, try fixture.mirrorFolder()] {
                for name in [try snapshotName(oldDay), redundant] + decoys {
                    try Data(name.utf8).write(to: folder.appending(path: name))
                }
                try manager.createDirectory(
                    at: folder.appending(path: try snapshotName(oldDay + .hours(2))),
                    withIntermediateDirectories: false)
                try manager.createSymbolicLink(
                    at: folder.appending(path: try snapshotName(oldDay + .hours(3))),
                    withDestinationURL: outsideFile)
                try manager.createSymbolicLink(
                    at: folder.appending(path: try snapshotName(oldDay + .hours(4))),
                    withDestinationURL: fixture.layout.book)
                #expect(
                    mkfifo(
                        folder.appending(path: try snapshotName(oldDay + .hours(5))).path(
                            percentEncoded: false), 0o644) == 0)
            }
            let before = try DirectorySnapshot(directory)

            #expect(try fixture.save(draft(2), at: start + .minutes(10)) == bothWritten)
            let after = try DirectorySnapshot(directory)
            let removed = Set(before.entries.keys).subtracting(after.entries.keys)
            #expect(
                removed == [
                    fixture.relative(fixture.layout.snapshots.appending(path: redundant)),
                    fixture.relative(try fixture.mirrorFolder().appending(path: redundant)),
                ], "pruning ran, and removed only the redundant snapshot")
            let saved: Set = ["Novel.sceneit/book.json", "Novel.sceneit/book.json.bak1"]
            for (path, entry) in before.entries where !removed.contains(path) && !saved.contains(path) {
                #expect(after.entries[path]?.contents == entry.contents, "\(path)")
            }
            for folder in [fixture.layout.snapshots, try fixture.mirrorFolder()] {
                let pipe = folder.appending(path: try snapshotName(oldDay + .hours(5)))
                #expect(
                    manager.fileExists(atPath: pipe.path(percentEncoded: false)), "the pipe is still there")
            }
        }
    }
}

/// Every way a snapshot can fail: the save still succeeds, `book.json` holds the new book,
/// and the failure is reported.
@Suite struct BackupKeeperFailureTests {
    enum Fault: CaseIterable, CustomTestStringConvertible {
        case listPackage, writePackageSnapshot, publishPackageSnapshot, prunePackage
        case listMirror, writeMirrorSnapshot, recordBookID, recordMirrorOwner, identifyPackage
        case missingApplicationSupport, mirrorRootNotWritable

        var testDescription: String { "\(self)" }

        /// The step each destination reports; `nil` where it writes its snapshot.
        var expected: (package: SnapshotStep?, mirror: SnapshotStep?) {
            switch self {
            case .listPackage: (.list, nil)
            case .writePackageSnapshot, .publishPackageSnapshot: (.write, nil)
            case .prunePackage: (.prune, nil)
            case .listMirror: (nil, .list)
            case .writeMirrorSnapshot: (nil, .write)
            case .recordBookID: (nil, .writeBookID)
            case .recordMirrorOwner: (nil, .writeMirrorOwner)
            case .identifyPackage: (nil, .identifyPackage)
            case .missingApplicationSupport, .mirrorRootNotWritable: (nil, .createFolder)
            }
        }

        /// Whether an earlier session already made the book's id and mirror folder.
        var hasEarlierSession: Bool {
            ![.recordBookID, .recordMirrorOwner, .missingApplicationSupport, .mirrorRootNotWritable].contains(
                self)
        }
    }

    @Test(arguments: Fault.allCases)
    func aFailedSnapshotNeverFailsTheSave(_ fault: Fault) throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(
                directory,
                mirrorRoot: fault == .missingApplicationSupport
                    ? "Missing/Scene It/Backups" : "Application Support/Scene It/Backups")
            let now = start + .days(3)
            let packageSnapshots = fixture.layout.snapshots
            if fault.hasEarlierSession {
                try fixture.save(draft(1), at: start + .hours(2))
            }
            // Snapshots of an earlier day, one of them redundant.
            try Data().write(to: packageSnapshots.appending(path: snapshotName(start)))
            try Data().write(to: packageSnapshots.appending(path: snapshotName(start + .hours(1))))
            let snapshot = try snapshotName(now)
            let applicationSupport = directory.appending(path: "Application Support")

            switch fault {
            case .listPackage:
                fixture.fileSystem.inject(.fail(.list(fixture.relative(packageSnapshots)), cause: .io))
            case .writePackageSnapshot:
                fixture.fileSystem.inject(
                    .fail(
                        .writeTemporary(fixture.relative(packageSnapshots.appending(path: snapshot))),
                        cause: .noSpace))
            case .publishPackageSnapshot:
                fixture.fileSystem.inject(
                    .fail(.publish(fixture.relative(packageSnapshots.appending(path: snapshot))), cause: .io))
            case .prunePackage:
                let redundant = packageSnapshots.appending(path: try snapshotName(start + .hours(1)))
                fixture.fileSystem.inject(
                    .fail(.remove(fixture.relative(redundant)), cause: .permissionDenied))
            case .listMirror:
                fixture.fileSystem.inject(
                    .fail(.list(fixture.relative(try fixture.mirrorFolder())), cause: .io))
            case .writeMirrorSnapshot:
                fixture.fileSystem.inject(
                    .fail(
                        .writeTemporary(
                            fixture.relative(try fixture.mirrorFolder().appending(path: snapshot))),
                        cause: .noSpace))
            case .recordBookID:
                fixture.fileSystem.inject(
                    .fail(.writeTemporary(fixture.relative(fixture.layout.bookID)), cause: .noSpace))
            case .recordMirrorOwner:
                let id = UUID()
                try Data("\(id.uuidString)\n".utf8).write(to: fixture.layout.bookID)
                let record = BackupMirror.packageRecord(in: fixture.mirror.folder(for: id))
                fixture.fileSystem.inject(.fail(.publish(fixture.relative(record)), cause: .io))
            case .identifyPackage:
                fixture.fileSystem.inject(.fail(.identify(fixture.relative(fixture.layout.root)), cause: .io))
            case .missingApplicationSupport:
                break
            case .mirrorRootNotWritable:
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o555], ofItemAtPath: applicationSupport.path(percentEncoded: false))
            }
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: applicationSupport.path(percentEncoded: false))
            }

            let report = try fixture.save(draft(9), at: now)
            #expect(try Data(contentsOf: fixture.layout.book) == encoded(draft(9)), "the save went ahead")
            #expect(try BookPackage.open(at: fixture.layout.root).book == draft(9))

            let expected = fault.expected
            for (outcome, step) in [(report.package, expected.package), (report.mirror, expected.mirror)] {
                if let step {
                    guard case .failed(.fileSystem(let actual, _)) = outcome else {
                        Issue.record("expected a failure at \(step), got \(outcome)")
                        continue
                    }
                    #expect(actual == step)
                } else {
                    #expect(outcome == .written)
                }
            }
            #expect(report.failures.count == 1)
            #expect(try temporaryFiles(in: packageSnapshots).isEmpty)
        }
    }
}

@Suite struct ListAndRemoveTests {
    @Test func contentsReportsEachKindAndRemoveNeverTakesADirectory() throws {
        try withTemporaryDirectory { directory in
            let manager = FileManager.default
            try Data("x".utf8).write(to: directory.appending(path: "file"))
            try manager.createDirectory(
                at: directory.appending(path: "folder"), withIntermediateDirectories: false)
            try manager.createSymbolicLink(
                at: directory.appending(path: "link"), withDestinationURL: directory.appending(path: "file"))
            let fileSystem = LocalFileSystem()
            #expect(
                Set(try fileSystem.contents(of: directory)) == [
                    DirectoryEntry(name: "file", kind: .file),
                    DirectoryEntry(name: "folder", kind: .directory),
                    DirectoryEntry(name: "link", kind: .symbolicLink),
                ])

            let refused = try #require(throws: FileSystemError.self) {
                try fileSystem.remove(directory.appending(path: "folder"))
            }
            #expect(refused.operation == .remove)
            try fileSystem.remove(directory.appending(path: "link"))
            #expect(manager.fileExists(atPath: directory.appending(path: "file").path(percentEncoded: false)))
            try fileSystem.remove(directory.appending(path: "file"))
            let missing = try #require(throws: FileSystemError.self) {
                try fileSystem.remove(directory.appending(path: "file"))
            }
            #expect(missing.cause == .notFound)
            #expect(
                try fileSystem.contents(of: directory) == [DirectoryEntry(name: "folder", kind: .directory)])
            let absent = try #require(throws: FileSystemError.self) {
                try fileSystem.contents(of: directory.appending(path: "absent"))
            }
            #expect(absent.cause == .notFound)
        }
    }

    @Test func identityFollowsTheDirectoryNotThePath() throws {
        try withTemporaryDirectory { directory in
            let manager = FileManager.default
            let first = directory.appending(path: "first")
            try manager.createDirectory(at: first, withIntermediateDirectories: false)
            let fileSystem = LocalFileSystem()
            let identity = try #require(try fileSystem.identity(of: first))
            let moved = directory.appending(path: "moved")
            try manager.moveItem(at: first, to: moved)
            #expect(try fileSystem.identity(of: moved) == identity)
            try manager.copyItem(at: moved, to: first)
            let copied = try #require(try fileSystem.identity(of: first))
            #expect(copied != identity && copied.volume == identity.volume)
        }
    }
}
