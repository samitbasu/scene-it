import Foundation
import Testing

@testable import SceneItCore

/// Monday 2 November 2026, 09:00 UTC.
private let start = Date(timeIntervalSince1970: 1_793_610_000)

/// A book package and a mirror root (standing in for Application Support) in one temporary
/// directory, on a file system that can fail chosen calls.
private struct KeeperFixture {
    let directory: URL
    let fileSystem: FaultInjectingFileSystem
    let mirror: BackupMirror
    var package: BookPackage
    var keeper: BackupKeeper

    init(_ directory: URL, mirrorRoot: String = "Application Support/Scene It/Backups") throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory.appending(path: "Application Support"), withIntermediateDirectories: false)
        fileSystem = FaultInjectingFileSystem(root: directory)
        mirror = BackupMirror(root: directory.appending(path: mirrorRoot, directoryHint: .isDirectory))
        package = try BookPackage.create(
            at: directory.appending(path: "Novel.sceneit"), title: "Novel", fileSystem: fileSystem
        ).package
        keeper = BackupKeeper(package: package, mirror: mirror)
    }

    var layout: PackageLayout { package.layout }

    /// Opens another package with the same mirror, as the store would.
    mutating func switchTo(_ url: URL) throws {
        package = try BookPackage.open(at: url, fileSystem: fileSystem).package
        keeper = BackupKeeper(package: package, mirror: mirror)
    }

    /// Saves `book` and, if it was written, keeps snapshots at `now`, the way the store does.
    @discardableResult
    func save(_ book: Book, at now: Date) throws -> SnapshotReport? {
        var report: SnapshotReport?
        let outcome = try package.save(book) { report = keeper.keep($0, now: now) }
        #expect(outcome == .saved(.intact))
        return report
    }

    func bookID() throws -> UUID {
        let text = try String(contentsOf: layout.bookID, encoding: .utf8)
        return try #require(UUID(uuidString: text.trimmingCharacters(in: .newlines)))
    }

    func mirrorFolder() throws -> URL { mirror.folder(for: try bookID()) }

    func mirrorFolders() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: mirror.root.path(percentEncoded: false)))
    }

    /// The snapshot names in `folder`, oldest first.
    func snapshots(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { SnapshotName(fileName: $0) != nil }.sorted()
    }

    func relative(_ url: URL) -> String {
        String(
            url.standardizedFileURL.path(percentEncoded: false).dropFirst(
                directory.standardizedFileURL.path(percentEncoded: false).count)
        ).trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
    }
}

private func snapshotName(_ date: Date) throws -> String {
    try #require(SnapshotName(date: date)).fileName
}

@Suite struct BackupKeeperTests {
    @Test func theFirstSaveSnapshotsThePublishedBytesInBothPlaces() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            let report = try fixture.save(draft(1), at: start)
            #expect(report == SnapshotReport(package: .written, mirror: .written))

            let published = try Data(contentsOf: fixture.layout.book)
            let name = try snapshotName(start)
            #expect(try Data(contentsOf: fixture.layout.snapshots.appending(path: name)) == published)
            #expect(try Data(contentsOf: fixture.mirrorFolder().appending(path: name)) == published)
            let recorded = try String(
                contentsOf: BackupMirror.packagePathFile(in: fixture.mirrorFolder()), encoding: .utf8)
            #expect(recorded == BackupMirror.path(of: fixture.layout.root) + "\n")
            #expect(try temporaryFiles(in: fixture.layout.snapshots).isEmpty)
        }
    }

    @Test func snapshotsFollowTheCadence() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            #expect(
                try fixture.save(draft(2), at: start + .minutes(9))
                    == SnapshotReport(package: .notDue, mirror: .notDue))
            #expect(
                try fixture.save(draft(3), at: start + .minutes(10))
                    == SnapshotReport(package: .written, mirror: .written))
            #expect(
                try fixture.snapshots(in: fixture.layout.snapshots) == [
                    try snapshotName(start), try snapshotName(start + .minutes(10)),
                ])
        }
    }

    @Test func anUnchangedSaveTakesNoSnapshot() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            var called = false
            #expect(try fixture.package.save(draft(1)) { _ in called = true } == .unchanged)
            #expect(!called)
        }
    }

    /// Four hours of saves every two minutes, every day for a week. Each save's snapshot
    /// step is run directly, since writing `book.json` 840 times only makes the test slow.
    @Test func aWeekOfSavesKeepsTheTiers() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            var published: PublishedBook?
            _ = try fixture.package.save(draft(1)) { published = $0 }
            let book = try #require(published)
            var now = start
            for day in 0..<7 {
                for minute in stride(from: 0, to: 4 * 60, by: 2) {
                    now = start + .days(day) + .minutes(minute)
                    let report = fixture.keeper.keep(book, now: now)
                    #expect(report.failures.isEmpty)
                    #expect(report.package == (minute % 10 == 0 ? .written : .notDue))
                }
            }
            let kept = try fixture.snapshots(in: fixture.layout.snapshots)
            #expect(try fixture.snapshots(in: fixture.mirrorFolder()) == kept)

            let dates = kept.compactMap { SnapshotName(fileName: $0)?.date }
            let lastDay = dates.filter { $0 > now - .hours(24) }
            #expect(lastDay.count == 24, "one every 10 minutes of the last session")
            for (earlier, later) in zip(lastDay, lastDay.dropFirst()) {
                #expect(later.timeIntervalSince(earlier) == 600)
            }
            let olderDays = dates.filter { $0 <= now - .hours(24) }
            #expect(olderDays == (0..<6).map { start + .days($0) }, "the first snapshot of each earlier day")
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
            #expect(
                try fixture.save(draft(2), at: start + .minutes(10))
                    == SnapshotReport(package: .written, mirror: .written))
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

    @Test func aMovedPackageKeepsItsIDAndFolder() throws {
        try withTemporaryDirectory { directory in
            var fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let id = try fixture.bookID()
            let moved = directory.appending(path: "Renamed.sceneit")
            try FileManager.default.moveItem(at: fixture.layout.root, to: moved)
            try fixture.switchTo(moved)
            try fixture.save(draft(2), at: start + .minutes(10))
            #expect(try fixture.bookID() == id)
            #expect(try fixture.mirrorFolders() == [id.uuidString])
            let recorded = try String(
                contentsOf: BackupMirror.packagePathFile(in: fixture.mirrorFolder()), encoding: .utf8)
            #expect(recorded == BackupMirror.path(of: moved) + "\n")
            #expect(try fixture.snapshots(in: fixture.mirrorFolder()).count == 2)
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
            #expect(
                try fixture.save(draft(2), at: start + .minutes(10))
                    == SnapshotReport(package: .written, mirror: .written))
            let newID = try fixture.bookID()
            #expect(newID != oldID)
            #expect(try fixture.mirrorFolders() == [oldID.uuidString, newID.uuidString])
            #expect(try fixture.snapshots(in: fixture.mirror.folder(for: oldID)) == [try snapshotName(start)])
        }
    }

    @Test func anUnreadableIDIsReportedAndLeftAlone() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let before = try Data(contentsOf: fixture.layout.bookID)
            fixture.fileSystem.inject(
                .fail(.read(fixture.relative(fixture.layout.bookID)), cause: .permissionDenied))
            let report = try #require(try fixture.save(draft(2), at: start + .minutes(10)))
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

    @Test func pruningNeverTouchesFilesThatAreNotExactlySnapshots() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let oldDay = start - .days(5)
            let redundant = try snapshotName(oldDay + .hours(1))
            let decoys = [
                "notes.txt", "book-20261028T090000Z.json.bak", "book-20261028T100000Z.JSON",
                "Book-20261028T113000Z.json", "book-2026-10-28T12:00:00Z.json", "book-20261028T1300Z.json",
                ".book-20261028T140000Z.json.tmp", "book-20261028T150000Z.json~",
            ]
            for folder in [fixture.layout.snapshots, try fixture.mirrorFolder()] {
                for name in [try snapshotName(oldDay), redundant] + decoys {
                    try Data(name.utf8).write(to: folder.appending(path: name))
                }
                try FileManager.default.createDirectory(
                    at: folder.appending(path: try snapshotName(oldDay + .hours(2))),
                    withIntermediateDirectories: false)
                try FileManager.default.createSymbolicLink(
                    at: folder.appending(path: try snapshotName(oldDay + .hours(3))),
                    withDestinationURL: folder.appending(path: "notes.txt"))
            }
            let before = try DirectorySnapshot(directory)

            #expect(
                try fixture.save(draft(2), at: start + .minutes(10))
                    == SnapshotReport(package: .written, mirror: .written))
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
        }
    }
}

/// Every way a snapshot can fail: the save still succeeds, `book.json` holds the new book,
/// and the failure is reported.
@Suite struct BackupKeeperFailureTests {
    enum Fault: CaseIterable, CustomTestStringConvertible {
        case listPackage, writePackageSnapshot, publishPackageSnapshot, prunePackage
        case listMirror, writeMirrorSnapshot, recordBookID, recordMirrorOwner
        case missingApplicationSupport, mirrorRootNotWritable

        var testDescription: String { "\(self)" }

        /// The destination that fails, and the step it reports.
        var expected: (package: SnapshotStep?, mirror: SnapshotStep?) {
            switch self {
            case .listPackage: (.list, nil)
            case .writePackageSnapshot, .publishPackageSnapshot: (.write, nil)
            case .prunePackage: (.prune, nil)
            case .listMirror: (nil, .list)
            case .writeMirrorSnapshot: (nil, .write)
            case .recordBookID: (nil, .writeBookID)
            case .recordMirrorOwner: (nil, .writeMirrorOwner)
            case .missingApplicationSupport, .mirrorRootNotWritable: (nil, .createFolder)
            }
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
            // An earlier session: a snapshot to prune, and (except where the fault is in
            // making them) the book's id and mirror folder.
            let packageSnapshots = fixture.layout.snapshots
            try Data().write(to: packageSnapshots.appending(path: snapshotName(start)))
            try Data().write(to: packageSnapshots.appending(path: try snapshotName(start + .hours(1))))
            if ![.recordBookID, .recordMirrorOwner, .missingApplicationSupport, .mirrorRootNotWritable]
                .contains(fault)
            {
                _ = fixture.keeper.keep(PublishedBook(data: Data()), now: start + .hours(2))
            }
            let mirrorFolder = { try fixture.mirrorFolder() }
            let snapshot = try snapshotName(now)

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
                fixture.fileSystem.inject(
                    .fail(
                        .remove(
                            fixture.relative(
                                packageSnapshots.appending(path: try snapshotName(start + .hours(1))))),
                        cause: .permissionDenied))
            case .listMirror:
                fixture.fileSystem.inject(.fail(.list(fixture.relative(try mirrorFolder())), cause: .io))
            case .writeMirrorSnapshot:
                fixture.fileSystem.inject(
                    .fail(
                        .writeTemporary(fixture.relative(try mirrorFolder().appending(path: snapshot))),
                        cause: .noSpace))
            case .recordBookID:
                fixture.fileSystem.inject(
                    .fail(.writeTemporary(fixture.relative(fixture.layout.bookID)), cause: .noSpace))
            case .recordMirrorOwner:
                let id = UUID()
                try Data("\(id.uuidString)\n".utf8).write(to: fixture.layout.bookID)
                let recording = BackupMirror.packagePathFile(in: fixture.mirror.folder(for: id))
                fixture.fileSystem.inject(.fail(.publish(fixture.relative(recording)), cause: .io))
            case .missingApplicationSupport:
                break
            case .mirrorRootNotWritable:
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o555],
                    ofItemAtPath: directory.appending(path: "Application Support").path)
            }
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: directory.appending(path: "Application Support").path)
            }

            let report = try #require(try fixture.save(draft(9), at: now))
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
}
