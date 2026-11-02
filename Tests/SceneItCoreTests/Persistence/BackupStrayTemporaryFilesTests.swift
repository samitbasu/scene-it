import Foundation
import Testing

@testable import SceneItCore

/// Monday 2 November 2026, 09:00 UTC.
private let start = Date(timeIntervalSince1970: 1_793_610_000)
/// When the next snapshot is due after the one at `start`.
private let due = start + .minutes(10)

private let bothWritten = SnapshotReport(package: .written, mirror: .written)

/// The two folders `BackupKeeper` writes into, each swept of its own stray temporary files.
enum SnapshotFolder: CaseIterable, CustomTestStringConvertible {
    case backups, mirror

    var testDescription: String { "\(self)" }

    func url(in fixture: KeeperFixture) throws -> URL {
        switch self {
        case .backups: fixture.layout.snapshots
        case .mirror: try fixture.mirrorFolder()
        }
    }

    /// The metadata file `BackupKeeper` writes in this folder.
    var metadata: String {
        switch self {
        case .backups: "book-id"
        case .mirror: "package.json"
        }
    }

    /// The other folder's metadata file, never written in this one.
    var foreignMetadata: String {
        switch self {
        case .backups: "package.json"
        case .mirror: "book-id"
        }
    }
}

/// A snapshot that was never published: no snapshot is ever taken at this time.
private func missedSnapshot() throws -> String {
    try #require(SnapshotName(date: start - .hours(1))).fileName
}

private func strayName(for destination: String) -> String {
    TemporaryFile.name(for: destination, id: UUID())
}

private func plant(_ data: Data, as name: String, in folder: URL, modified: Date = start) throws {
    let url = folder.appending(path: name)
    try data.write(to: url)
    try FileManager.default.setAttributes(
        [.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
}

private func exists(_ name: String, in folder: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(
        atPath: folder.appending(path: name).path(percentEncoded: false)))
        != nil
}

private func recoveredFiles(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        .filter { $0.hasPrefix("book.json.recovered-") }
}

private func strayContents(in folder: URL) throws -> [Data] {
    try temporaryFiles(in: folder).filter { TemporaryFile.destination(ofName: $0) != nil }
        .map { try Data(contentsOf: folder.appending(path: $0)) }
}

/// Every snapshot's bytes in `folder`.
private func snapshotContents(in folder: URL) throws -> Set<Data> {
    Set(
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { SnapshotName(fileName: $0) != nil }
            .map { try Data(contentsOf: folder.appending(path: $0)) })
}

/// Another program writing `url` the way most do: a new file renamed over the old one.
private func replace(_ url: URL, with data: Data) throws {
    let staged = url.deletingLastPathComponent().appending(path: "staged-\(UUID().uuidString)")
    try data.write(to: staged)
    guard rename(staged.path(percentEncoded: false), url.path(percentEncoded: false)) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
}

@Suite struct BackupStrayTemporaryFilesTests {
    @Test(arguments: SnapshotFolder.allCases)
    func aStrayHoldingASnapshotIsRemoved(_ snapshotFolder: SnapshotFolder) throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let folder = try snapshotFolder.url(in: fixture)
            let snapshot = try Data(
                contentsOf: folder.appending(path: try #require(SnapshotName(date: start)).fileName))
            let stray = strayName(for: try missedSnapshot())
            try plant(snapshot, as: stray, in: folder)

            #expect(try fixture.save(draft(2), at: due) == bothWritten)

            #expect(try snapshotContents(in: folder).contains(snapshot), "precondition: a snapshot holds it")
            #expect(!exists(stray, in: folder))
            #expect(try recoveredFiles(in: folder).isEmpty)
        }
    }

    /// A version only in `book.json`'s backups counts as kept in the package, but the mirror
    /// must outlive the package, so there only its own snapshots count.
    @Test(arguments: SnapshotFolder.allCases)
    func aStrayHoldingOnlyABackupIsRemovedFromThePackageAndRecoveredInTheMirror(
        _ snapshotFolder: SnapshotFolder
    ) throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            _ = try fixture.package.save(draft(2))
            let folder = try snapshotFolder.url(in: fixture)
            let backup = try encoded(draft(2))
            let stray = strayName(for: try missedSnapshot())
            try plant(backup, as: stray, in: folder)

            #expect(try fixture.save(draft(3), at: due) == bothWritten)

            #expect(packageKeeps(backup, fixture.layout), "precondition: a backup holds it")
            #expect(try !snapshotContents(in: folder).contains(backup), "precondition: no snapshot does")
            #expect(!exists(stray, in: folder))
            switch snapshotFolder {
            case .backups:
                #expect(try recoveredFiles(in: folder).isEmpty)
            case .mirror:
                let recovered = PackageLayout.recovered(in: folder, modified: start, attempt: 1)
                #expect(try Data(contentsOf: recovered) == backup)
            }
        }
    }

    @Test(arguments: SnapshotFolder.allCases)
    func aUniqueStrayIsRecoveredAndPruningNeverTouchesIt(_ snapshotFolder: SnapshotFolder) throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let folder = try snapshotFolder.url(in: fixture)
            let theirs = Data("a snapshot kept nowhere else".utf8)
            let stray = strayName(for: try missedSnapshot())
            try plant(theirs, as: stray, in: folder)

            #expect(try fixture.save(draft(2), at: due) == bothWritten)

            let recovered = PackageLayout.recovered(in: folder, modified: start, attempt: 1)
            #expect(recovered.lastPathComponent == "book.json.recovered-\(UTCStamp.string(for: start)).json")
            #expect(SnapshotName(fileName: recovered.lastPathComponent) == nil)
            #expect(!exists(stray, in: folder))
            #expect(try Data(contentsOf: recovered) == theirs)

            for minutes in stride(from: 20, through: 110, by: 10) {
                try fixture.save(draft(minutes), at: start + .minutes(minutes))
            }
            let redundant = try #require(SnapshotName(date: due)).fileName
            #expect(exists(redundant, in: folder), "precondition: a snapshot pruning will remove")
            for day in 2...3 {
                try fixture.save(draft(1000 + day), at: start + .days(day))
            }
            #expect(!exists(redundant, in: folder), "precondition: pruning ran")
            #expect(try Data(contentsOf: recovered) == theirs)
            #expect(try recoveredFiles(in: folder) == [recovered.lastPathComponent])
        }
    }

    @Test(arguments: SnapshotFolder.allCases)
    func aStrayMetadataFileIsRemovedWhileTheCurrentOneIsValid(_ snapshotFolder: SnapshotFolder) throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let folder = try snapshotFolder.url(in: fixture)
            let current = try Data(contentsOf: folder.appending(path: snapshotFolder.metadata))
            let strays = [Data("\(UUID().uuidString)\n".utf8), Data("garbage".utf8)].map { data in
                (name: strayName(for: snapshotFolder.metadata), data: data)
            }
            for stray in strays { try plant(stray.data, as: stray.name, in: folder) }

            #expect(try fixture.save(draft(2), at: due) == bothWritten)

            #expect(strays.allSatisfy { !exists($0.name, in: folder) })
            #expect(try Data(contentsOf: folder.appending(path: snapshotFolder.metadata)) == current)
            #expect(try recoveredFiles(in: folder).isEmpty)
        }
    }

    /// The package's sweep runs before the mirror's replaces a corrupt `book-id`.
    @Test func aStrayBookIDIsLeftWhileTheCurrentOneIsCorrupt() throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let folder = fixture.layout.snapshots
            try Data("not a uuid".utf8).write(to: fixture.layout.bookID)
            let stray = strayName(for: "book-id")
            try plant(Data("\(UUID().uuidString)\n".utf8), as: stray, in: folder)

            #expect(try fixture.save(draft(2), at: due) == bothWritten)
            #expect(exists(stray, in: folder))
            _ = try fixture.bookID()

            #expect(try fixture.save(draft(3), at: due + .minutes(10)) == bothWritten)
            #expect(!exists(stray, in: folder))
            #expect(try recoveredFiles(in: folder).isEmpty)
        }
    }

    @Test(arguments: SnapshotFolder.allCases)
    func decoysSurvive(_ snapshotFolder: SnapshotFolder) throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let folder = try snapshotFolder.url(in: fixture)
            let bait = try encoded(draft(1))
            let missed = try missedSnapshot()
            let stamp = UTCStamp.string(for: start - .hours(1))
            var decoys = [
                ".\(missed).\(UUID().uuidString.lowercased()).tmp", ".\(missed).\(UUID().uuidString).TMP",
                "\(missed).\(UUID().uuidString).tmp", ".\(missed).\(UUID().uuidString).tmp.bak",
                ".\(missed).crashed.tmp", ".Book-\(stamp).json.\(UUID().uuidString).tmp",
                ".book-\(stamp).JSON.\(UUID().uuidString).tmp",
                ".book-20261328T090000Z.json.\(UUID().uuidString).tmp",
                ".book-\(stamp.lowercased()).json.\(UUID().uuidString).tmp",
                ".book.json.\(UUID().uuidString).tmp", ".book.json.bak1.\(UUID().uuidString).tmp",
                ".notes.txt.\(UUID().uuidString).tmp", strayName(for: snapshotFolder.foreignMetadata),
                ".\(snapshotFolder.metadata)x.\(UUID().uuidString).tmp",
            ]
            for name in decoys { try plant(bait, as: name, in: folder) }
            let outside = directory.appending(path: "outside.json")
            try bait.write(to: outside)
            let link = strayName(for: missed)
            try FileManager.default.createSymbolicLink(
                at: folder.appending(path: link), withDestinationURL: outside)
            let subfolder = strayName(for: missed)
            try FileManager.default.createDirectory(
                at: folder.appending(path: subfolder), withIntermediateDirectories: false)
            let recent = strayName(for: missed)
            try plant(bait, as: recent, in: folder, modified: due - .minutes(9))
            decoys += [link, subfolder, recent]
            let control = strayName(for: missed)
            try plant(bait, as: control, in: folder)
            let before = try DirectorySnapshot(folder).entries.filter { decoys.contains($0.key) }
            #expect(before.count == decoys.count, "precondition: every decoy was planted")

            #expect(try fixture.save(draft(2), at: due) == bothWritten)

            #expect(!exists(control, in: folder), "precondition: a real stray with the same bytes is removed")
            #expect(try DirectorySnapshot(folder).entries.filter { decoys.contains($0.key) } == before)
            #expect(try Data(contentsOf: outside) == bait)
            #expect(try recoveredFiles(in: folder).isEmpty)
        }
    }

    @Test(arguments: SnapshotFolder.allCases)
    func aStrayIsSweptOnlyWhenASnapshotIsDueAndOldEnough(_ snapshotFolder: SnapshotFolder) throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let folder = try snapshotFolder.url(in: fixture)
            let stray = strayName(for: try missedSnapshot())
            try plant(try encoded(draft(1)), as: stray, in: folder, modified: start + .minutes(1))

            #expect(
                try fixture.save(draft(2), at: start + .minutes(5))
                    == SnapshotReport(package: .notDue, mirror: .notDue))
            #expect(exists(stray, in: folder))
            #expect(try fixture.save(draft(3), at: due) == bothWritten)
            #expect(exists(stray, in: folder), "nine minutes old")
            #expect(try fixture.save(draft(4), at: due + .minutes(10)) == bothWritten)
            #expect(!exists(stray, in: folder))
        }
    }

    enum SweepFault: CaseIterable {
        case list, open, moveAside, remove, rename
    }

    @Test(arguments: SnapshotFolder.allCases, SweepFault.allCases)
    func aFailedCleanupLeavesTheStrayAndTheSnapshotAlone(
        _ snapshotFolder: SnapshotFolder, _ fault: SweepFault
    ) throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let folder = try snapshotFolder.url(in: fixture)
            let bytes = try fault == .rename ? Data("unique".utf8) : encoded(draft(1))
            let missed = try missedSnapshot()
            try plant(bytes, as: strayName(for: missed), in: folder)
            let relativeFolder = fixture.relative(folder)
            let temporary = "\(relativeFolder)/temporary \(missed)"
            let recovered = PackageLayout.recovered(in: folder, modified: start, attempt: 1)
            let call: FaultInjectingFileSystem.Call =
                switch fault {
                case .list: .list(relativeFolder)
                case .open: .open(temporary)
                case .moveAside: .publish(temporary)
                case .remove: .remove(temporary)
                case .rename: .publish(fixture.relative(recovered))
                }
            // The keeper lists the folder once before the sweep does.
            let skipping = fault == .list ? 1 : 0
            fixture.fileSystem.inject(.fail(call, skipping: skipping))
            fixture.fileSystem.clearCalls()

            #expect(try fixture.save(draft(2), at: due) == bothWritten)

            #expect(
                fixture.fileSystem.calls.count { $0 == call } > skipping,
                "precondition: the cleanup reached the failing call")
            #expect(try strayContents(in: folder) == [bytes])
            #expect(!exists(recovered.lastPathComponent, in: folder))
            #expect(try snapshotContents(in: folder).contains(try encoded(draft(2))))
        }
    }

    @Test(arguments: SnapshotFolder.allCases)
    func aStrayReplacedJustBeforeTheRemovalSurvives(_ snapshotFolder: SnapshotFolder) throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let folder = try snapshotFolder.url(in: fixture)
            let missed = try missedSnapshot()
            let stray = folder.appending(path: strayName(for: missed))
            try plant(try encoded(draft(1)), as: stray.lastPathComponent, in: folder)
            let theirs = Data("written by another program between the comparison and the removal".utf8)
            let removal = FaultInjectingFileSystem.Call.remove(
                "\(fixture.relative(folder))/temporary \(missed)")
            fixture.fileSystem.before(removal) { try? replace(stray, with: theirs) }

            #expect(try fixture.save(draft(2), at: due) == bothWritten)

            #expect(fixture.fileSystem.calls.contains(removal), "precondition: the hook ran")
            #expect(try Data(contentsOf: stray) == theirs)
            #expect(try strayContents(in: folder) == [theirs])
        }
    }

    /// Nothing is swept through a link, as nothing is snapshotted or pruned through one.
    @Test(arguments: SnapshotFolder.allCases)
    func aLinkedFolderIsNeverSwept(_ snapshotFolder: SnapshotFolder) throws {
        try withTemporaryDirectory { directory in
            let fixture = try KeeperFixture(directory)
            try fixture.save(draft(1), at: start)
            let folder = try snapshotFolder.url(in: fixture)
            try plant(try encoded(draft(1)), as: strayName(for: try missedSnapshot()), in: folder)
            try plant(Data("unique".utf8), as: strayName(for: try missedSnapshot()), in: folder)
            try plant(Data("stale".utf8), as: strayName(for: snapshotFolder.metadata), in: folder)
            let outside = directory.appending(path: "Outside")
            try FileManager.default.moveItem(at: folder, to: outside)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
            let before = try DirectorySnapshot(outside)

            let report = try fixture.save(draft(2), at: due)

            let expected =
                switch snapshotFolder {
                case .backups:
                    SnapshotReport(package: .failed(.notARealFolder), mirror: .failed(.notARealFolder))
                case .mirror: SnapshotReport(package: .written, mirror: .failed(.notARealFolder))
                }
            #expect(report == expected)
            #expect(try DirectorySnapshot(outside) == before)
        }
    }
}
