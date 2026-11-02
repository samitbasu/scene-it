import Darwin
import Foundation
import Testing

@testable import SceneItCore

@Suite struct ExternalModificationTests {
    enum Change: CaseIterable {
        case rewritten, removed, touched, replacedWithIdenticalBytes, replacedByADirectory

        func apply(to book: URL) throws {
            switch self {
            case .rewritten:
                try encoded(draft(7)).write(to: book)
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
        var refusal: ExternalChange? {
            switch self {
            case .rewritten: .changed
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
            guard let refusal = change.refusal else {
                #expect(try package.save(draft(9)) == .saved(.intact))
                try expectLayout(url.layout, book: 9, backups: [0, 1, 2])
                #expect(try package.save(draft(10)) == .saved(.intact), "the adopted stamp sticks")
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
            let outcome = try package.save(draft(9), onExternalChange: .overwriteKeepingTheirsAsBackup)
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
            let outcome = try package.save(draft(9), onExternalChange: .overwriteKeepingTheirsAsBackup)
            #expect(outcome == .saved(.intact))
            try expectLayout(url.layout, book: 9, backups: [1, 2, 3])
        }
    }

    @Test func overwritingNeverReplacesSomethingThatIsNotAFile() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            try Change.replacedByADirectory.apply(to: url.layout.book)
            #expect(throws: SaveError.externallyModified(.notAFile)) {
                try package.save(draft(9), onExternalChange: .overwriteKeepingTheirsAsBackup)
            }
        }
    }

    @Test func reopeningAfterAnExternalChangeSavesAgain() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            try Change.rewritten.apply(to: url.layout.book)
            #expect(throws: SaveError.externallyModified(.changed)) { try package.save(draft(9)) }

            let reopened = try BookPackage.open(at: url)
            #expect(reopened.book == (try draft(7)))
            #expect(try reopened.package.save(draft(9)) == .saved(.intact))
            try expectLayout(url.layout, book: 9, backups: [7, 1, 2])
        }
    }
}

@Suite struct WriteProtectionTests {
    @Test func aSaveKeepsBookJsonsPermissions() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try BookPackage.create(at: url, title: "Novel").package
            let path = url.layout.book.path(percentEncoded: false)
            #expect(chmod(path, 0o600) == 0)
            #expect(try package.save(draft(1)) == .saved(.intact))
            var info = stat()
            #expect(stat(path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o600)
            #expect(stat(url.layout.backup(.bak1).path(percentEncoded: false), &info) == 0)
            #expect(info.st_mode & 0o777 == 0o600, "a private book's backups stay private")
        }
    }

    @Test func aReadOnlyBookIsRefused() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            #expect(chmod(url.layout.book.path(percentEncoded: false), 0o444) == 0)
            let before = try DirectorySnapshot(url)
            #expect(throws: SaveError.writeProtected(.readOnly)) { try package.save(draft(9)) }
            #expect(try DirectorySnapshot(url) == before)
        }
    }

    @Test func aLockedBookIsRefused() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let path = url.layout.book.path(percentEncoded: false)
            #expect(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
            defer { chflags(path, 0) }
            let before = try DirectorySnapshot(url)
            #expect(throws: SaveError.writeProtected(.locked)) { try package.save(draft(9)) }
            #expect(try DirectorySnapshot(url) == before)
        }
    }
}

/// A damaged backup slot must never stop `book.json` from being saved.
@Suite struct DamagedBackupTests {
    @Test func anUnreadableBak1CountsAsDifferent() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let bak1 = url.layout.backup(.bak1).path(percentEncoded: false)
            #expect(chmod(bak1, 0) == 0)
            #expect(try package.save(draft(9)) == .saved(.intact))
            #expect(chmod(url.layout.backup(.bak2).path(percentEncoded: false), 0o644) == 0)
            try expectLayout(url.layout, book: 9, backups: [0, 1, 2])
        }
    }

    @Test func aDirectoryAtBak3DegradesTheBackupsButSaves() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let bak3 = url.layout.backup(.bak3)
            try FileManager.default.removeItem(at: bak3)
            try FileManager.default.createDirectory(at: bak3, withIntermediateDirectories: false)
            try Data().write(to: bak3.appending(path: "x"))
            let outcome = try package.save(draft(9))
            guard case .saved(.degraded(let error)) = outcome else {
                Issue.record("expected degraded backups, got \(outcome)")
                return
            }
            #expect(error.operation == .move)
            let (book, backups) = url.layout.contents()
            #expect(book == (try encoded(draft(9))))
            #expect(backups[.bak1] == (try encoded(draft(0))))
            #expect(backups[.bak2] == (try encoded(draft(1))))
        }
    }

    @Test func aLockedBak1DegradesTheBackupsButSaves() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let bak1 = url.layout.backup(.bak1).path(percentEncoded: false)
            #expect(chflags(bak1, UInt32(UF_IMMUTABLE)) == 0)
            defer { chflags(bak1, 0) }
            let outcome = try package.save(draft(9))
            guard case .saved(.degraded) = outcome else {
                Issue.record("expected degraded backups, got \(outcome)")
                return
            }
            #expect(url.layout.contents().book == (try encoded(draft(9))))
            #expect(try temporaryFiles(in: url).isEmpty)
        }
    }
}
