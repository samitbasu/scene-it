import Foundation
import Testing

@testable import SceneItCore

/// A package holding `draft(0)`, saved, on a file system that can fail chosen calls. Calls are
/// named relative to the package: "Archive/save0001.md", "Archive/temporary save0001.md".
struct FilingFixture {
    let url: URL
    let fileSystem: FaultInjectingFileSystem
    let package: BookPackage

    init(_ directory: URL) throws {
        url = directory.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
        fileSystem = FaultInjectingFileSystem(root: url)
        package = try BookPackage.create(at: url, title: "Novel", fileSystem: fileSystem).package
        #expect(try package.save(draft(0)).backupStatus == .intact)
    }

    var layout: PackageLayout { package.layout }

    static let day = CalendarDay(year: 2026, month: 11, day: 1)!
    static let record = FilingRecord(
        filed: day, tags: ["draft 4", "before the ending"], note: "Before the rewrite")

    @discardableResult
    func file(_ book: Book? = nil, _ record: FilingRecord = record) throws -> FilingOutcome {
        try package.fileCopy(of: book ?? draft(0), as: record).outcome
    }

    func copy(_ number: Int) -> URL {
        layout.filedCopy(FiledCopyNumber(number)!)
    }

    /// The names in `Archive/`, sorted.
    func archiveNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: layout.archive.path(percentEncoded: false))
            .sorted()
    }

    func index() throws -> ArchiveIndex {
        ArchiveIndexFormat.parse(try Data(contentsOf: layout.archiveIndex), filed: { _ in Self.day }).index
    }
}

/// What can tell a file was changed: its bytes, inode, modification time and flags.
struct FileFingerprint: Equatable {
    let contents: Data
    let fileNumber: Int?
    let modified: Date?
    let immutable: Bool

    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        contents = try Data(contentsOf: url)
        fileNumber = attributes[.systemFileNumber] as? Int
        modified = attributes[.modificationDate] as? Date
        immutable = attributes[.immutable] as? Bool == true
    }
}

@Suite struct FilingTests {
    static func number(_ value: Int) -> FiledCopyNumber { FiledCopyNumber(value)! }

    @Test func aFiledCopyIsExactlyBookMdLockedAndIndexed() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            let outcome = try fixture.file()
            #expect(outcome.number == Self.number(1))
            #expect(outcome.lock == .locked)
            #expect(outcome.isComplete)

            let copy = try Data(contentsOf: fixture.copy(1))
            #expect(copy == (try Data(contentsOf: fixture.layout.book)))
            #expect(copy == (try BookFormat.verifiedSerialization(of: draft(0))))
            #expect(try isImmutable(fixture.copy(1)))
            guard case .file(_, .locked?)? = try LocalFileSystem().item(at: fixture.copy(1)) else {
                Issue.record("the copy isn't locked")
                return
            }
            let expected = FiledCopy(
                number: Self.number(1), filed: FilingFixture.day, tags: ["draft 4", "before the ending"],
                note: "Before the rewrite", counts: FiledCopyCounts(try draft(0)))
            #expect(try fixture.index().copies == [expected])
            #expect(outcome.index == .updated(try fixture.index()))
            #expect(try fixture.archiveNames() == ["index.md", "save0001.md"], "no temporary file is left")
        }
    }

    @Test func theBookIsSavedFirstSoTheCopyHoldsWhatWasFiled() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            let filed = try fixture.package.fileCopy(of: draft(5), as: FilingFixture.record)
            #expect(filed.saved.published != nil, "the book had unsaved changes")
            let book = try Data(contentsOf: fixture.layout.book)
            #expect(book == (try encoded(draft(5))))
            #expect(try Data(contentsOf: fixture.copy(1)) == book)
            #expect(fixture.layout.contents().backups[.bak1] == (try encoded(draft(0))))
        }
    }

    @Test func countsAreTheStorysScenesWordsAndCommentsOnly() throws {
        var book = try draft(0)
        #expect(!book.boneyard.isEmpty, "precondition: the Boneyard has scenes")
        let counts = FiledCopyCounts(book)
        #expect(counts.scenes == book.scenes.count)
        #expect(counts.words == book.scenes.reduce(0) { $0 + $1.wordCount.words })
        #expect(counts.comments == book.scenes.reduce(0) { $0 + $1.comments.count })
        #expect(counts.comments > 0, "precondition: the story has comments")
        book.boneyard = []
        #expect(FiledCopyCounts(book) == counts, "the Boneyard isn't counted")
    }

    @Test func numberingIsOneMoreThanTheHighestFileWhateverTheGaps() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            for (number, text) in [(1, "first"), (7, "seventh")] {
                try Data(text.utf8).write(to: fixture.copy(number))
            }
            let planted = try [1, 7].map { try FileFingerprint(fixture.copy($0)) }
            #expect(try fixture.file().number == Self.number(8))
            #expect(try [1, 7].map { try FileFingerprint(fixture.copy($0)) } == planted)
            let index = try fixture.index()
            #expect(index.copies.map(\.number) == [1, 7, 8].map(Self.number))
            #expect(index.copies.map(\.tags) == [[], [], ["draft 4", "before the ending"]])
        }
    }

    @Test func aNumberTakenDuringTheFilingMovesItAlongAndReplacesNothing() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            let racer = fixture.copy(1)
            fixture.fileSystem.before(.publish("Archive/save0001.md")) {
                try? Data("another filing".utf8).write(to: racer)
            }
            let outcome = try fixture.file()
            #expect(outcome.number == Self.number(2))
            #expect(try Data(contentsOf: racer) == Data("another filing".utf8))
            #expect(try Data(contentsOf: fixture.copy(2)) == (try Data(contentsOf: fixture.layout.book)))
            #expect(try fixture.index().copies.map(\.number) == [1, 2].map(Self.number))
        }
    }

    @Test func twoFilingsInARowGetConsecutiveNumbers() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            #expect(try fixture.file().number == Self.number(1))
            #expect(try fixture.file(draft(1)).number == Self.number(2))
            #expect(try Data(contentsOf: fixture.copy(1)) == (try encoded(draft(0))))
            #expect(try Data(contentsOf: fixture.copy(2)) == (try encoded(draft(1))))
            #expect(try fixture.index().copies.map(\.number) == [1, 2].map(Self.number))
        }
    }

    // MARK: Nothing touches a filed copy

    @Test func savesSnapshotsSweepsAndIndexEditsNeverTouchAFiledCopy() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            try fixture.file()
            let before = try FileFingerprint(fixture.copy(1))
            #expect(before.immutable, "precondition: locked")

            let keeper = BackupKeeper(
                package: fixture.package, mirror: BackupMirror(root: directory.appending(path: "Mirror")))
            let start = Date.now - .days(10)
            for step in 1...12 {
                let outcome = try fixture.package.save(draft(step % 5 + 1))
                if let published = outcome.published {
                    _ = keeper.keep(published, now: start + .hours(step * 20))
                }
            }
            try fixture.file(draft(3), FilingRecord(filed: FilingFixture.day, tags: ["later"]))
            _ = fixture.package.reconcileArchive()

            #expect(try FileFingerprint(fixture.copy(1)) == before)
            #expect(try fixture.index().copies.map(\.number) == [1, 2].map(Self.number))
        }
    }

    @Test func theFileSystemSeamRefusesToChangeAFiledCopy() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            try fixture.file()
            let before = try FileFingerprint(fixture.copy(1))
            try expectSeamRefuses(fixture.copy(1), in: fixture.layout)
            #expect(try FileFingerprint(fixture.copy(1)) == before)
        }
    }

    /// The seam's own refusal, which holds on volumes that can't lock a file.
    @Test func theSeamRefusesEvenAFiledCopyThatIsntLocked() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            let copy = fixture.copy(3)
            try Data("filed on a FAT disk".utf8).write(to: copy)
            #expect(try !isImmutable(copy), "precondition: only the seam stands in the way")
            let before = try FileFingerprint(copy)
            try expectSeamRefuses(copy, in: fixture.layout)
            #expect(try FileFingerprint(copy) == before)

            let outside = fixture.layout.root.appending(path: "save0003.md")
            try Data("not in Archive".utf8).write(to: outside)
            try LocalFileSystem().remove(outside)
            #expect(!FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
        }
    }

    private func expectSeamRefuses(_ copy: URL, in layout: PackageLayout) throws {
        let fileSystem = LocalFileSystem()
        #expect(PackageLayout.isFiledCopy(copy), "precondition")
        #expect(throws: FileSystemError(.remove, copy, .filedCopy)) { try fileSystem.remove(copy) }
        let elsewhere = layout.root.appending(path: "elsewhere.md")
        #expect(throws: FileSystemError(.move, copy, .filedCopy)) {
            try fileSystem.move(copy, over: elsewhere)
        }
        let replacement = try fileSystem.writeTemporary(Data("x".utf8), for: copy, permissionsFrom: copy)
        defer { fileSystem.discard(replacement.url) }
        #expect(throws: FileSystemError(.move, copy, .filedCopy)) {
            try fileSystem.move(replacement.url, over: copy)
        }
        #expect(throws: FileSystemError(.exchange, copy, .filedCopy)) {
            try fileSystem.exchange(replacement, with: copy)
        }
        #expect(throws: FileSystemError(.publish, copy, .alreadyExists)) {
            try fileSystem.publish(replacement, as: copy)
        }
    }

    @Test func theKernelRefusesToChangeALockedCopyToo() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            try fixture.file()
            let copy = fixture.copy(1)
            let before = try FileFingerprint(copy)
            #expect(throws: (any Error).self) { try FileManager.default.removeItem(at: copy) }
            #expect(throws: (any Error).self) { try Data("x".utf8).write(to: copy) }
            #expect(throws: (any Error).self) {
                try FileManager.default.moveItem(at: copy, to: directory.appending(path: "moved.md"))
            }
            #expect(try FileFingerprint(copy) == before)
        }
    }

    // MARK: Failures

    /// A step of filing that can fail before the copy is published.
    enum CopyFault: CaseIterable, CustomTestStringConvertible {
        case listArchive, writeCopy, readCopyBack, publishCopy

        var fault: FaultInjectingFileSystem.Fault {
            switch self {
            case .listArchive: .fail(.list("Archive"))
            case .writeCopy: .fail(.writeTemporary("Archive/save0001.md"), cause: .noSpace)
            case .readCopyBack: .fail(.read("Archive/temporary save0001.md"))
            case .publishCopy: .fail(.publish("Archive/save0001.md"))
            }
        }

        var testDescription: String { "\(self)" }
    }

    @Test(arguments: CopyFault.allCases)
    func aCopyThatFailsLeavesNothingFiled(_ fault: CopyFault) throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            let index = try Data(contentsOf: fixture.layout.archiveIndex)
            fixture.fileSystem.inject(fault.fault)
            let failure = #expect(throws: FilingFailure.self) { try fixture.file() }
            if fault == .readCopyBack {
                #expect(failure == .copyDiffers)
            } else {
                guard case .fileSystem = failure else {
                    Issue.record("expected a file-system failure, got \(String(describing: failure))")
                    return
                }
            }
            fixture.fileSystem.clearFault()
            #expect(try fixture.archiveNames() == ["index.md"], "no copy and no temporary file")
            #expect(try Data(contentsOf: fixture.layout.archiveIndex) == index)
            #expect(try Data(contentsOf: fixture.layout.book) == (try encoded(draft(0))))
            #expect(try fixture.file().number == Self.number(1), "filing works once the fault clears")
        }
    }

    @Test func aLockTheVolumeRefusesIsReportedAndTheCopyStaysFiled() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            fixture.fileSystem.inject(.fail(.makeImmutable("Archive/save0001.md"), cause: .unsupported))
            let outcome = try fixture.file()
            guard case .notLocked(.refused(let error)) = outcome.lock else {
                Issue.record("expected a refused lock, got \(outcome.lock)")
                return
            }
            #expect(error.cause == .unsupported)
            #expect(!outcome.isComplete)
            #expect(try !isImmutable(fixture.copy(1)))
            #expect(try Data(contentsOf: fixture.copy(1)) == (try encoded(draft(0))))
            #expect(try fixture.index().copies.map(\.number) == [Self.number(1)], "it's indexed anyway")
            #expect(ArchiveWording.notice(for: .filed(outcome)) != nil, "the writer is told")
        }
    }

    @Test func aLockTheVolumeDoesntKeepIsReported() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            fixture.fileSystem.inject(.noEffect(.makeImmutable("Archive/save0001.md")))
            let outcome = try fixture.file()
            #expect(outcome.lock == .notLocked(.flagNotKept))
            #expect(try !isImmutable(fixture.copy(1)), "precondition: the flag really isn't there")
            #expect(ArchiveWording.notice(for: .filed(outcome)) != nil)
        }
    }

    @Test func anIndexThatCantBeWrittenLeavesACopyTheNextReconciliationLists() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            let index = try Data(contentsOf: fixture.layout.archiveIndex)
            fixture.fileSystem.inject(.fail(.move("Archive/temporary index.md", over: "Archive/index.md")))
            let outcome = try fixture.file()
            guard case .notUpdated(.notWritten(.fileSystem)) = outcome.index else {
                Issue.record("expected the index write to fail, got \(outcome.index)")
                return
            }
            #expect(outcome.lock == .locked)
            #expect(try Data(contentsOf: fixture.layout.archiveIndex) == index)
            #expect(try fixture.archiveNames() == ["index.md", "save0001.md"])

            fixture.fileSystem.clearFault()
            let reconciled = fixture.package.reconcileArchive()
            #expect(reconciled.notices == [.listedWithoutEntry(Self.number(1))])
            let expected = FiledCopy(
                number: Self.number(1), filed: CalendarDay(.now, in: .current),
                counts: FiledCopyCounts(try draft(0)))
            #expect(try fixture.index().copies == [expected])
            #expect(fixture.package.reconcileArchive().notices.isEmpty, "reconciled once")
        }
    }

    @Test func anIndexThatCantBeReadIsNeverReplaced() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            let index = try Data(contentsOf: fixture.layout.archiveIndex)
            fixture.fileSystem.inject(.fail(.read("Archive/index.md"), cause: .permissionDenied))
            let outcome = try fixture.file()
            guard case .notUpdated(.couldNotRead) = outcome.index else {
                Issue.record("expected the index read to fail, got \(outcome.index)")
                return
            }
            let reconciled = fixture.package.reconcileArchive()
            #expect(
                reconciled.notices.first.map { if case .indexUnreadable = $0 { true } else { false } } == true
            )
            #expect(reconciled.index.copies.map(\.number) == [Self.number(1)], "listed for the cabinet")
            fixture.fileSystem.clearFault()
            #expect(try Data(contentsOf: fixture.layout.archiveIndex) == index)
        }
    }

    @Test func anIndexThatIsntAFileIsLeftAlone() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            try FileManager.default.removeItem(at: fixture.layout.archiveIndex)
            try FileManager.default.createDirectory(
                at: fixture.layout.archiveIndex, withIntermediateDirectories: false)
            let outcome = try fixture.file()
            guard case .notUpdated(.couldNotRead) = outcome.index else {
                Issue.record("expected the index read to fail, got \(outcome.index)")
                return
            }
            _ = fixture.package.reconcileArchive()
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(
                    atPath: fixture.layout.archiveIndex.path(percentEncoded: false), isDirectory: &isDirectory
                ))
            #expect(isDirectory.boolValue)
        }
    }

    @Test func anIndexFromANewerVersionIsNeverRewritten() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            let newer = Data("---\nformat: 3\n---\n\n## save0001.md\nfiled: 2026-09-14\ncolour: blue\n".utf8)
            try newer.write(to: fixture.layout.archiveIndex)
            let outcome = try fixture.file()
            #expect(outcome.index == .notUpdated(.newerFormat(FormatVersion(3))))
            #expect(outcome.number == Self.number(1), "the copy is still filed")
            let reconciled = fixture.package.reconcileArchive()
            #expect(reconciled.rewrite == .refused(newerFormat: FormatVersion(3)))
            #expect(reconciled.notices.contains(.indexFromNewerVersion(FormatVersion(3))))
            #expect(try Data(contentsOf: fixture.layout.archiveIndex) == newer)
        }
    }

    @Test func anotherProgramsVersionRefusesTheFiling() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            try writeExternally(draft(7), to: fixture.url)
            #expect(throws: FilingFailure.save(try changed(to: 7))) { try fixture.file() }
            #expect(try fixture.archiveNames() == ["index.md"])
        }
    }

    @Test func aPackageWithoutAnArchiveGetsOne() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            try FileManager.default.removeItem(at: fixture.layout.archive)
            #expect(fixture.package.reconcileArchive().index == ArchiveIndex(), "no archive is an empty one")
            #expect(
                !FileManager.default.fileExists(atPath: fixture.layout.archive.path(percentEncoded: false)))
            #expect(try fixture.file().isComplete)
            #expect(try fixture.index().copies.map(\.number) == [Self.number(1)])
        }
    }

    @Test func anArchiveThatIsntAFolderRefusesTheFiling() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            try FileManager.default.removeItem(at: fixture.layout.archive)
            try Data("not a folder".utf8).write(to: fixture.layout.archive)
            #expect(throws: FilingFailure.archiveNotAFolder) { try fixture.file() }
            #expect(try Data(contentsOf: fixture.layout.archive) == Data("not a folder".utf8))
        }
    }

    // MARK: Reconciling on disk

    @Test func reconcilingWritesTheIndexOnlyWhenItChanges() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            try fixture.file()
            let index = try Data(contentsOf: fixture.layout.archiveIndex)
            fixture.fileSystem.clearCalls()
            #expect(fixture.package.reconcileArchive().rewrite == .unneeded)
            #expect(fixture.fileSystem.calls.filter(\.isMutation).isEmpty)
            #expect(try Data(contentsOf: fixture.layout.archiveIndex) == index)
        }
    }

    @Test func aReadOnlyReconciliationWritesNothing() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            try fixture.file()
            try Data(contentsOf: fixture.copy(1)).write(to: fixture.copy(4))
            try Data("---\nformat: 2\n---\n".utf8).write(to: fixture.layout.archiveIndex)
            let before = try DirectorySnapshot(fixture.layout.archive)
            let opened = try BookPackage.open(at: fixture.url, fileSystem: fixture.fileSystem)
            #expect(opened.readOnlyReason == .openElsewhere, "precondition: the fixture holds the lock")
            guard case .readOnly(let readOnly, _) = opened else { return }
            let reconciled = readOnly.reconcileArchive(fileSystem: fixture.fileSystem)
            #expect(reconciled.index.copies.map(\.number) == [1, 4].map(Self.number))
            #expect(reconciled.rewrite == .needed)
            #expect(try DirectorySnapshot(fixture.layout.archive) == before)
        }
    }
}
