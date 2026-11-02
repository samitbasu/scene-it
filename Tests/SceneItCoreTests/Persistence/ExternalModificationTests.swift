import Darwin
import Foundation
import Testing

@testable import SceneItCore

@Suite struct ExternalModificationTests {
    enum Change: CaseIterable {
        case rewritten, rewrittenInPlaceKeepingSizeAndTime, removed, touched, replacedWithIdenticalBytes
        case replacedByADirectory

        func apply(to book: URL) throws {
            switch self {
            case .rewritten:
                try encoded(draft(7)).write(to: book)
            case .rewrittenInPlaceKeepingSizeAndTime:
                let path = book.path(percentEncoded: false)
                var before = stat()
                #expect(lstat(path, &before) == 0)
                let theirs = try encoded(draft(7))
                #expect(theirs.count == before.st_size, "precondition: same size")
                let handle = try FileHandle(forWritingTo: book)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: theirs)
                try handle.close()
                var times = [before.st_atimespec, before.st_mtimespec]
                #expect(utimensat(AT_FDCWD, path, &times, 0) == 0)
                var after = stat()
                #expect(lstat(path, &after) == 0)
                #expect(
                    after.st_ino == before.st_ino
                        && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                    "precondition: same inode and modification time")
            case .removed:
                try FileManager.default.removeItem(at: book)
            case .touched:
                let later = Date.now.addingTimeInterval(60)
                try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: book.path())
            case .replacedWithIdenticalBytes:
                let bytes = try Data(contentsOf: book)
                try FileManager.default.removeItem(at: book)
                try bytes.write(to: book)
            case .replacedByADirectory:
                try FileManager.default.removeItem(at: book)
                try FileManager.default.createDirectory(at: book, withIntermediateDirectories: false)
            }
        }

        /// What `.refuse` reports; `nil` when the bytes are still ours and the save proceeds.
        func refusal() throws -> ExternalChange? {
            switch self {
            case .rewritten, .rewrittenInPlaceKeepingSizeAndTime: .changed(theirs: try version(7))
            case .removed: .removed
            case .replacedByADirectory: .notAFile
            case .touched, .replacedWithIdenticalBytes: nil
            }
        }
    }

    @Test(arguments: Change.allCases)
    func refusingNeverOverwritesAnotherProgramsChange(_ change: Change) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            try change.apply(to: url.layout.book)
            guard let refusal = try change.refusal() else {
                #expect(try package.save(draft(9)) == .saved(.intact))
                try expectLayout(url.layout, book: 9, backups: [0, 1, 2])
                return
            }
            let before = try DirectorySnapshot(url)
            #expect(throws: SaveError.externallyModified(refusal)) { try package.save(draft(9)) }
            #expect(throws: SaveError.externallyModified(refusal)) { try package.save(draft(0)) }
            #expect(try DirectorySnapshot(url) == before)
        }
    }

    @Test func overwritingKeepsTheirVersionAsTheNewestBackup() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            try Change.rewritten.apply(to: url.layout.book)
            let outcome = try package.save(draft(9), onExternalChange: overwriting(7))
            #expect(outcome == .saved(.intact))
            try expectLayout(url.layout, book: 9, backups: [7, 1, 2])
            #expect(try package.save(draft(10)) == .saved(.intact), "later saves need no policy")
        }
    }

    @Test func overwritingRecreatesARemovedBook() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            try Change.removed.apply(to: url.layout.book)
            #expect(throws: SaveError.externallyModified(.removed)) {
                try package.save(draft(9), onExternalChange: overwriting(7))
            }
            let outcome = try package.save(draft(9), onExternalChange: .recreate)
            #expect(outcome == .saved(.intact))
            try expectLayout(url.layout, book: 9, backups: [1, 2, 3])
        }
    }

    @Test func overwritingNeverReplacesSomethingThatIsNotAFile() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            try Change.replacedByADirectory.apply(to: url.layout.book)
            for policy in [try overwriting(7), .recreate] {
                #expect(throws: SaveError.externallyModified(.notAFile)) {
                    try package.save(draft(9), onExternalChange: policy)
                }
            }
        }
    }

    @Test func overwritingRefusesWhenTheirVersionCantBeBackedUp() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let bak1 = url.layout.backup(.bak1).path(percentEncoded: false)
            #expect(chflags(bak1, UInt32(UF_IMMUTABLE)) == 0)
            defer { chflags(bak1, 0) }
            try Change.rewritten.apply(to: url.layout.book)
            let error = try #require(throws: SaveError.self) {
                try package.save(draft(9), onExternalChange: overwriting(7))
            }
            guard case .couldNotBackUpTheirVersion = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(url.layout.contents().book == (try encoded(draft(7))))
        }
    }

    @Test func keepingMyVersionNeverOverwritesALaterVersion() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            try Change.rewritten.apply(to: url.layout.book)
            #expect(throws: try changed(to: 7)) { try package.save(draft(9)) }
            try encoded(draft(8)).write(to: url.layout.book)
            let before = try DirectorySnapshot(url)
            #expect(throws: try changed(to: 8)) {
                try package.save(draft(9), onExternalChange: overwriting(7))
            }
            #expect(try DirectorySnapshot(url) == before)
            #expect(try package.save(draft(9), onExternalChange: overwriting(8)) == .saved(.intact))
            try expectLayout(url.layout, book: 9, backups: [8, 1, 2])
        }
    }

    @Test func reopeningAfterAnExternalChangeSavesAgain() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            try Change.rewritten.apply(to: url.layout.book)
            #expect(throws: try changed(to: 7)) { try package.save(draft(9)) }

            let reopened = try BookPackage.open(at: url)
            #expect(reopened.book == (try draft(7)))
            #expect(try reopened.package.save(draft(9)) == .saved(.intact))
            try expectLayout(url.layout, book: 9, backups: [7, 1, 2])
        }
    }
}

/// Another program writes `book.json` after the save checked it but before the save replaced it.
@Suite struct ConcurrentChangeTests {
    enum Replacement: CaseIterable {
        /// The volume can swap: the check happens after the swap.
        case exchange
        /// FAT/exFAT: a re-check just before a plain rename.
        case recheckThenRename
    }

    private func package(
        _ url: URL, _ replacement: Replacement
    ) throws -> (BookPackage, FaultInjectingFileSystem) {
        let fileSystem = FaultInjectingFileSystem(root: url)
        let package = try makeFullPackage(at: url, fileSystem: fileSystem)
        if replacement == .recheckThenRename {
            fileSystem.inject(.fail(.exchange("book.json"), cause: .unsupported))
        }
        return (package, fileSystem)
    }

    /// `.keepingTheirs` approves exactly the version that lands during the save.
    enum Policy: CaseIterable {
        case refuse, keepingTheirs
    }

    @Test(arguments: Replacement.allCases, Policy.allCases)
    func aWriteDuringTheSaveIsNeverLost(_ replacement: Replacement, _ choice: Policy) throws {
        let policy = choice == .refuse ? ExternalChangePolicy.refuse : try overwriting(7)
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let (package, fileSystem) = try package(url, replacement)
            let book = url.layout.book
            let theirs = try encoded(draft(7))
            fileSystem.before(.writeTemporary("book.json")) { try? theirs.write(to: book) }
            #expect(throws: try changed(to: 7)) {
                try package.save(draft(9), onExternalChange: policy)
            }
            try expectLayout(url.layout, book: 7, backups: [0, 1, 2])
            #expect(try temporaryFiles(in: url).isEmpty)
        }
    }

    @Test(arguments: Replacement.allCases)
    func withoutAConcurrentWriteTheSaveSucceeds(_ replacement: Replacement) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let (package, _) = try package(url, replacement)
            #expect(try package.save(draft(9)) == .saved(.intact))
            try expectLayout(url.layout, book: 9, backups: [0, 1, 2])
            #expect(try temporaryFiles(in: url).isEmpty)
        }
    }

    @Test func ifTheirVersionCantBeSwappedBackItIsKeptUnderAConflictName() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let (package, fileSystem) = try package(url, .exchange)
            let book = url.layout.book
            let theirs = try encoded(draft(7))
            fileSystem.before(.writeTemporary("book.json")) { try? theirs.write(to: book) }
            fileSystem.inject(.fail(.exchange("book.json"), skipping: 1))
            let error = try #require(throws: SaveError.self) { try package.save(draft(9)) }
            guard case .externallyModified(.keptAsConflict(let fileName)) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(fileName.hasPrefix("book.json.conflict-"))
            #expect(try Data(contentsOf: url.appending(path: fileName)) == theirs)
            #expect(url.layout.contents().book == (try encoded(draft(9))))
            fileSystem.clearFault()
            #expect(try package.save(draft(10)) == .saved(.intact), "book.json holds our save")
        }
    }
}

extension ConcurrentChangeTests {
    /// Triple fault: theirs1 lands before the swap, theirs2 lands after it, and the swap-back
    /// fails. book.json now holds theirs2, which must never be mistaken for our own save.
    @Test func aThirdWriteAfterAFailedSwapBackIsNotTakenForOurs() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            let package = try makeFullPackage(at: url, fileSystem: fileSystem)
            let book = url.layout.book
            let theirs1 = try encoded(draft(7))
            let theirs2 = try encoded(draft(8))
            fileSystem.before(.writeTemporary("book.json")) { try? theirs1.write(to: book) }
            fileSystem.before(.read("temporary book.json")) { try? theirs2.write(to: book) }
            fileSystem.inject(.fail(.exchange("book.json"), skipping: 1))
            let error = try #require(throws: SaveError.self) { try package.save(draft(9)) }
            guard case .externallyModified(.keptAsConflict(let fileName)) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(try Data(contentsOf: url.appending(path: fileName)) == theirs1)
            #expect(url.layout.contents().book == theirs2, "precondition: theirs2 landed in book.json")

            fileSystem.inject(.fail(.publish("book.json.bak1")))
            #expect(throws: try changed(to: 8)) { try package.save(draft(10)) }
            #expect(url.layout.contents().book == theirs2)
        }
    }

    @Test func conflictsInTheSameSecondGetDistinctVisibleNames() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let layout = url.layout
            let now = Date.now
            #expect(layout.conflict(at: now, attempt: 1).lastPathComponent.hasPrefix("book.json.conflict-"))
            #expect(layout.conflict(at: now, attempt: 2).lastPathComponent.hasSuffix("-2"))
            #expect(layout.conflict(at: now, attempt: 1) != layout.conflict(at: now, attempt: 2))
        }
    }
}

@Suite struct WriteProtectionTests {
    @Test func aSaveKeepsBookJsonsPermissionsAndGivesThemToTheNewBackup() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try BookPackage.create(at: url, title: "Novel").package
            let path = url.layout.book.path(percentEncoded: false)
            #expect(chmod(path, 0o4600) == 0)
            #expect(try package.save(draft(1)) == .saved(.intact))
            var info = stat()
            #expect(stat(path, &info) == 0)
            #expect(info.st_mode & 0o7777 == 0o600, "the permission bits, without setuid")
            #expect(stat(url.layout.backup(.bak1).path(percentEncoded: false), &info) == 0)
            #expect(info.st_mode & 0o7777 == 0o600, "a private book's backups stay private")
        }
    }

    @Test(arguments: [WriteProtection.readOnly, .locked])
    func aProtectedBookIsRefused(_ protection: WriteProtection) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let path = url.layout.book.path(percentEncoded: false)
            switch protection {
            case .readOnly: #expect(chmod(path, 0o444) == 0)
            case .locked: #expect(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
            }
            defer { chflags(path, 0) }
            let before = try DirectorySnapshot(url)
            #expect(throws: SaveError.writeProtected(protection)) { try package.save(draft(9)) }
            #expect(try DirectorySnapshot(url) == before)
        }
    }

    @Test func anAppendOnlyBookCountsAsLocked() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let path = url.layout.book.path(percentEncoded: false)
            #expect(chflags(path, UInt32(UF_APPEND)) == 0)
            defer { chflags(path, 0) }
            for number in [9, 10] {
                #expect(throws: SaveError.writeProtected(.locked)) { try package.save(draft(number)) }
            }
            try expectLayout(url.layout, book: 0, backups: [1, 2, 3])
        }
    }
}

/// A damaged backup slot never destroys a distinct version, and never stops our own save
/// (ADR 0019); the outcome says the previous version wasn't backed up.
@Suite struct DamagedBackupTests {
    @Test func anUnreadableBak1CountsAsDifferent() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            #expect(chmod(url.layout.backup(.bak1).path(percentEncoded: false), 0) == 0)
            #expect(try package.save(draft(9)) == .saved(.intact))
            #expect(chmod(url.layout.backup(.bak2).path(percentEncoded: false), 0o644) == 0)
            try expectLayout(url.layout, book: 9, backups: [0, 1, 2])
        }
    }

    enum Damage: CaseIterable {
        case directoryAtBak3, directoryAtBak2, lockedBak1

        /// Which drafts survive in bak1…bak3 after saving draft 9.
        var survivors: [Int?] {
            switch self {
            case .directoryAtBak3: [1, 2, nil]
            case .directoryAtBak2: [1, nil, 3]
            case .lockedBak1: [1, nil, 2]
            }
        }
    }

    @Test(arguments: Damage.allCases)
    func aDamagedSlotLeavesTheVersionsAloneAndStillSaves(_ damage: Damage) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let layout = url.layout
            let bak1 = layout.backup(.bak1).path(percentEncoded: false)
            defer { chflags(bak1, 0) }
            switch damage {
            case .directoryAtBak3, .directoryAtBak2:
                let slot = layout.backup(damage == .directoryAtBak3 ? .bak3 : .bak2)
                try FileManager.default.removeItem(at: slot)
                try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: false)
                try Data("x".utf8).write(to: slot.appending(path: "x"))
            case .lockedBak1:
                #expect(chflags(bak1, UInt32(UF_IMMUTABLE)) == 0)
            }
            for number in [9, 10] {
                let outcome = try package.save(draft(number))
                guard case .saved(.previousVersionNotBackedUp) = outcome else {
                    Issue.record("expected the previous version not backed up, got \(outcome)")
                    return
                }
            }
            let (book, backups) = layout.contents()
            #expect(book == (try encoded(draft(10))))
            for slot in BackupSlot.allCases {
                let expected = try damage.survivors[slot.rawValue - 1].map { try encoded(draft($0)) }
                #expect(backups[slot] == expected, "\(slot)")
            }
            #expect(try temporaryFiles(in: url).isEmpty)
        }
    }
}
