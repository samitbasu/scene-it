import Foundation
import Testing

@testable import SceneItCore

@Suite struct StrayTemporaryFilesTests {
    /// Comfortably past `StrayTemporaryFiles.minimumAge`, on a whole second so the recovery
    /// name is predictable.
    static let longAgo = Date(
        timeIntervalSince1970: (Date.now - .hours(2)).timeIntervalSince1970.rounded(.down))

    @Test func theNameMatchesExactlyWhatWriteTemporaryWrites() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appending(path: "book.json")
            let temporary = try LocalFileSystem().writeTemporary(
                Data("x".utf8), for: destination, permissionsFrom: destination)
            #expect(TemporaryFile.destination(ofName: temporary.url.lastPathComponent) == "book.json")
        }
        let id = UUID().uuidString
        #expect(TemporaryFile.destination(ofName: ".book.json.\(id).tmp") == "book.json")
        #expect(TemporaryFile.destination(ofName: ".book.json.bak1.\(id).tmp") == "book.json.bak1")
        for nearMiss in Self.nearMisses(id) {
            let destination = TemporaryFile.destination(ofName: nearMiss)
            #expect(
                destination == nil || !["book.json", "book.json.bak1"].contains(destination), "\(nearMiss)")
        }
    }

    /// Names a save never gives a temporary `book.json` or `bak1`.
    static func nearMisses(_ id: String) -> [String] {
        [
            ".book.json.\(id.lowercased()).tmp", ".BOOK.JSON.\(id).tmp", ".Book.json.\(id).tmp",
            ".book.json.\(id).TMP", ".book.JSON.\(id).tmp", "book.json.\(id).tmp", ".book.json.\(id).tmp.bak",
            "..book.json.\(id).tmp", ".book.json.\(id).tmp ", " .book.json.\(id).tmp",
            ".book.json.\(id.replacingOccurrences(of: "-", with: "")).tmp", ".book.json.\(id)0.tmp",
            ".book.json.\(id.dropLast()).tmp", ".book.json.bak2.\(id).tmp", ".book.json.bak3.\(id).tmp",
            ".book.json.bak4.\(id).tmp", ".book.jsonx.\(id).tmp", ".index.json.\(id).tmp",
            ".book.json.crashed.tmp",
            ".book.json\(id).tmp", ".book.json.\(id)tmp", ".book.json.\(id).tmp\n", ".lock",
        ]
    }

    @Test func decoysSurviveASave() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let bait = try encoded(draft(0))
            // A fresh UUID for each, so names differing only in case don't collide on a
            // case-insensitive volume.
            var decoys = Self.nearMisses(UUID().uuidString).indices
                .map { Self.nearMisses(UUID().uuidString)[$0] }
                .filter { !$0.contains("\n") && $0 != ".lock" }
            for name in decoys { try plant(bait, as: name, in: url) }
            let outside = directory.appending(path: "outside.json")
            try bait.write(to: outside)
            let link = Self.temporaryName()
            try FileManager.default.createSymbolicLink(
                at: url.appending(path: link), withDestinationURL: outside)
            let folder = Self.temporaryName()
            try FileManager.default.createDirectory(
                at: url.appending(path: folder), withIntermediateDirectories: false)
            let recent = Self.temporaryName()
            try plant(bait, as: recent, in: url, modified: .now - .minutes(9))
            decoys += [link, folder, recent]
            let control = Self.temporaryName()
            try plant(bait, as: control, in: url)
            let before = try DirectorySnapshot(url).entries.filter { decoys.contains($0.key) }
            #expect(before.count == decoys.count, "precondition: every decoy was planted")

            #expect(try package.save(draft(9)).backupStatus == .intact)

            #expect(packageKeeps(bait, package.layout), "precondition: the decoys' bytes are in a backup")
            #expect(!exists(control, in: url), "precondition: a real stray with the same bytes is removed")
            #expect(try DirectorySnapshot(url).entries.filter { decoys.contains($0.key) } == before)
            #expect(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: url.appending(path: link).path(percentEncoded: false))
                    == outside.path(percentEncoded: false))
            #expect(try Data(contentsOf: outside) == bait)
            #expect(try recoveredFiles(in: url).isEmpty)
        }
    }

    @Test(arguments: [9, 0, 1, 2])
    func aStrayHoldingTheBookOrABackupIsRemoved(_ number: Int) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let stray = Self.temporaryName()
            let bakStray = Self.temporaryName(for: "book.json.bak1")
            try plant(try encoded(draft(number)), as: stray, in: url)
            try plant(try encoded(draft(number)), as: bakStray, in: url)

            #expect(try package.save(draft(9)).backupStatus == .intact)

            try expectLayout(package.layout, book: 9, backups: [0, 1, 2])
            #expect(!exists(stray, in: url))
            #expect(!exists(bakStray, in: url))
            #expect(try recoveredFiles(in: url).isEmpty)
        }
    }

    @Test func aStrayHoldingASnapshotIsRemoved() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let bytes = try encoded(draft(7))
            let snapshot = try #require(SnapshotName(date: Self.longAgo)).fileName
            try plant(bytes, as: snapshot, in: package.layout.snapshots)
            let stray = Self.temporaryName()
            try plant(bytes, as: stray, in: url)

            #expect(try package.save(draft(9)).backupStatus == .intact)

            #expect(!packageKeeps(bytes, package.layout), "precondition: only the snapshot holds these bytes")
            #expect(!exists(stray, in: url))
            #expect(try Data(contentsOf: package.layout.snapshots.appending(path: snapshot)) == bytes)
        }
    }

    @Test func aStrayHoldingAnythingElseIsRenamedNeverRemoved() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let theirs = Data("another program's version, kept nowhere else".utf8)
            let stray = Self.temporaryName()
            try plant(theirs, as: stray, in: url)

            #expect(try package.save(draft(9)).backupStatus == .intact)

            let recovered = package.layout.recovered(modified: Self.longAgo, attempt: 1)
            #expect(
                recovered.lastPathComponent
                    == "book.json.recovered-\(UTCStamp.string(for: Self.longAgo)).json")
            #expect(!exists(stray, in: url))
            #expect(try Data(contentsOf: recovered) == theirs)
            #expect(try recoveredFiles(in: url) == [recovered.lastPathComponent])
        }
    }

    @Test func aTakenRecoveryNameIsNeverReplaced() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let layout = package.layout
            let earlier = [Data("first".utf8), Data("second".utf8)]
            for (index, data) in earlier.enumerated() {
                try plant(
                    data, as: layout.recovered(modified: Self.longAgo, attempt: index + 1).lastPathComponent,
                    in: url)
            }
            let strays = [Self.temporaryName(), Self.temporaryName()]
            let contents = [Data("third".utf8), Data("fourth".utf8)]
            for (stray, data) in zip(strays, contents) { try plant(data, as: stray, in: url) }

            #expect(try package.save(draft(9)).backupStatus == .intact)

            for (index, data) in earlier.enumerated() {
                #expect(
                    try Data(contentsOf: layout.recovered(modified: Self.longAgo, attempt: index + 1)) == data
                )
            }
            let renamed = try [3, 4].map {
                try Data(contentsOf: layout.recovered(modified: Self.longAgo, attempt: $0))
            }
            #expect(Set(renamed) == Set(contents))
            #expect(
                layout.recovered(modified: Self.longAgo, attempt: 3).lastPathComponent.hasSuffix("Z-3.json"))
            #expect(strays.allSatisfy { !exists($0, in: url) })
        }
    }

    @Test func aStrayYoungerThanTheMinimumAgeIsLeftAlone() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let stray = Self.temporaryName()
            try plant(try encoded(draft(0)), as: stray, in: url)
            let sweep = StrayTemporaryFiles(layout: package.layout, fileSystem: LocalFileSystem())

            sweep.sweep(now: Self.longAgo + StrayTemporaryFiles.minimumAge - .seconds(1))
            #expect(exists(stray, in: url))
            sweep.sweep(now: Self.longAgo + StrayTemporaryFiles.minimumAge)
            #expect(!exists(stray, in: url))
        }
    }

    enum SweepFault: CaseIterable {
        case list, open, moveAside, remove, rename
    }

    @Test(arguments: SweepFault.allCases)
    func aFailedCleanupLeavesTheStrayAndTheSaveAlone(_ fault: SweepFault) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            let package = try makeFullPackage(at: url, fileSystem: fileSystem)
            let bytes = try fault == .rename ? Data("unique".utf8) : encoded(draft(0))
            try plant(bytes, as: Self.temporaryName(), in: url)
            let recovered = package.layout.recovered(modified: Self.longAgo, attempt: 1).lastPathComponent
            let call: FaultInjectingFileSystem.Call =
                switch fault {
                case .list: .list("")
                case .open: .open("temporary book.json")
                case .moveAside: .publish("temporary book.json")
                case .remove: .remove("temporary book.json")
                case .rename: .publish(recovered)
                }
            if fault == .list {
                fileSystem.inject(.fail(call))
            } else {
                fileSystem.before(.list("")) { fileSystem.inject(.fail(call)) }
            }

            #expect(try package.save(draft(9)).backupStatus == .intact)

            #expect(fileSystem.calls.contains(call), "precondition: the cleanup reached the failing call")
            try expectLayout(package.layout, book: 9, backups: [0, 1, 2])
            #expect(try temporaryContents(in: url) == [bytes])
            #expect(!exists(recovered, in: url))
        }
    }

    @Test func aStrayReplacedJustBeforeTheRemovalSurvives() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            let package = try makeFullPackage(at: url, fileSystem: fileSystem)
            let stray = url.appending(path: Self.temporaryName())
            try plant(try encoded(draft(0)), as: stray.lastPathComponent, in: url)
            let theirs = Data("written by another program between the comparison and the removal".utf8)
            fileSystem.before(.remove("temporary book.json")) { try? Self.replace(stray, with: theirs) }

            #expect(try package.save(draft(9)).backupStatus == .intact)

            #expect(fileSystem.calls.contains(.remove("temporary book.json")), "precondition: the hook ran")
            #expect(try Data(contentsOf: stray) == theirs)
            #expect(try temporaryContents(in: url) == [theirs])
        }
    }

    @Test func aStrayReplacedJustBeforeItIsMovedAsideIsRecoveredNotRemoved() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            let package = try makeFullPackage(at: url, fileSystem: fileSystem)
            let stray = url.appending(path: Self.temporaryName())
            try plant(try encoded(draft(0)), as: stray.lastPathComponent, in: url)
            let theirs = Data("written by another program after the comparison".utf8)
            fileSystem.before(.publish("temporary book.json")) { try? Self.replace(stray, with: theirs) }

            #expect(try package.save(draft(9)).backupStatus == .intact)

            #expect(fileSystem.calls.contains(.publish("temporary book.json")), "precondition: the hook ran")
            #expect(!fileSystem.calls.contains(.remove("temporary book.json")))
            #expect(try temporaryContents(in: url).isEmpty)
            let recovered = try recoveredFiles(in: url)
            #expect(recovered.count == 1)
            #expect(try recovered.map { try Data(contentsOf: url.appending(path: $0)) } == [theirs])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aPipeSwappedInForAStrayNeitherBlocksNorIsTouched() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            let package = try makeFullPackage(at: url, fileSystem: fileSystem)
            let stray = url.appending(path: Self.temporaryName())
            try plant(try encoded(draft(0)), as: stray.lastPathComponent, in: url)
            fileSystem.before(.open("temporary book.json")) {
                try? FileManager.default.removeItem(at: stray)
                _ = stray.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) }
            }

            #expect(try package.save(draft(9)).backupStatus == .intact)

            #expect(fileSystem.calls.contains(.open("temporary book.json")), "precondition: the hook ran")
            #expect(try LocalFileSystem().item(at: stray) == .other)
            #expect(try recoveredFiles(in: url).isEmpty)
        }
    }

    @Test func aStrayOfASizeNothingKeptHasIsRecoveredWithoutReadingAnything() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            let package = try makeFullPackage(at: url, fileSystem: fileSystem)
            let theirs = Data("short".utf8)
            try plant(theirs, as: Self.temporaryName(), in: url)
            fileSystem.clearCalls()

            #expect(try package.save(draft(9)).backupStatus == .intact)

            let sweep = fileSystem.calls.drop { $0 != .list("") }
            #expect(sweep.contains(.open("temporary book.json")), "precondition: the sweep found the stray")
            #expect(!sweep.contains { if case .read = $0 { true } else { false } })
            let recovered = try recoveredFiles(in: url).map { try Data(contentsOf: url.appending(path: $0)) }
            #expect(recovered == [theirs])
        }
    }

    @Test func eachKeptVersionIsReadAtMostOncePerSweep() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            let package = try makeFullPackage(at: url, fileSystem: fileSystem)
            let kept = try encoded(draft(0))
            var unique = kept
            unique[unique.startIndex] ^= 1
            let strays = [kept, unique, unique + Data("!".utf8)]
            for data in strays { try plant(data, as: Self.temporaryName(), in: url) }
            fileSystem.clearCalls()

            #expect(try package.save(draft(9)).backupStatus == .intact)

            let sweep = fileSystem.calls.drop { $0 != .list("") }
            let reads = sweep.compactMap { call -> String? in
                if case .read(let name) = call { name } else { nil }
            }
            #expect(!reads.isEmpty, "precondition: some kept version was compared")
            #expect(reads.count == Set(reads).count, "\(reads)")
            #expect(try temporaryContents(in: url).isEmpty)
            let recovered = try recoveredFiles(in: url).map { try Data(contentsOf: url.appending(path: $0)) }
            #expect(Set(recovered) == [unique, unique + Data("!".utf8)])
        }
    }

    @Test func anUnchangedSaveDoesNotClean() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let stray = Self.temporaryName()
            try plant(try encoded(draft(0)), as: stray, in: url)

            #expect(try package.save(draft(0)) == .unchanged)

            #expect(exists(stray, in: url))
        }
    }

    @Test func openingNeverCleansEditingOrReadOnly() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let before: DirectorySnapshot
            do {
                let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
                try plant(try encoded(draft(0)), as: Self.temporaryName(), in: url)
                try plant(Data("unique".utf8), as: Self.temporaryName(), in: url)
                before = try DirectorySnapshot(url)

                let readOnly = try BookPackage.open(at: url)
                #expect(readOnly.readOnlyReason == .openElsewhere)
                #expect(try DirectorySnapshot(url) == before)
                withExtendedLifetime(package) {}
            }

            let editing = try BookPackage.open(at: url)
            #expect(editing.editable != nil)
            #expect(try DirectorySnapshot(url) == before)
        }
    }

    static func temporaryName(for destination: String = "book.json") -> String {
        TemporaryFile.name(for: destination, id: UUID())
    }

    private func plant(_ data: Data, as name: String, in directory: URL, modified: Date = longAgo) throws {
        let url = directory.appending(path: name)
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
    }

    /// Another program writing `url` the way most do: a new file (new inode, new modification
    /// time) renamed over whatever is there, if anything.
    private static func replace(_ url: URL, with data: Data) throws {
        let staged = url.deletingLastPathComponent().appending(path: "staged-\(UUID().uuidString)")
        try data.write(to: staged)
        guard rename(staged.path(percentEncoded: false), url.path(percentEncoded: false)) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private func temporaryContents(in url: URL) throws -> [Data] {
        try temporaryFiles(in: url).filter { TemporaryFile.destination(ofName: $0) != nil }
            .map { try Data(contentsOf: url.appending(path: $0)) }
    }

    private func exists(_ name: String, in directory: URL) -> Bool {
        let path = directory.appending(path: name).path(percentEncoded: false)
        return (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    private func recoveredFiles(in url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
            .filter { $0.hasPrefix("book.json.recovered-") }
    }
}
