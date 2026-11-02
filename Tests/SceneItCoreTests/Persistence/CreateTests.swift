import Foundation
import Testing

@testable import SceneItCore

@Suite struct CreateTests {
    @Test func aNewPackageHoldsAnEmptyBookAnEmptyArchiveAndNoBackups() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "My Novel.sceneit")
            let created = try BookPackage.create(at: url, title: "My Novel")
            #expect(created.book == Book(title: "My Novel"))
            #expect(created.book.scenes.isEmpty)

            let entries = try DirectorySnapshot(url).entries
            #expect(Set(entries.keys) == ["book.json", "Archive", "Archive/index.json", "Backups"])
            #expect(entries["Archive/index.json"]?.contents == Data(#"{"copies":[]}"#.utf8))
            #expect(entries["book.json"]?.contents == (try encoded(Book(title: "My Novel"))))

            #expect(try BookPackage.open(at: url).book == created.book)
        }
    }

    @Test func creatingOverAnythingThatExistsFailsWithoutTouchingIt() throws {
        try withTemporaryDirectory { directory in
            let package = directory.appending(path: "Existing.sceneit")
            _ = try BookPackage.create(at: package, title: "Existing")
            let file = directory.appending(path: "File.sceneit")
            try Data("not a book".utf8).write(to: file)
            let before = try DirectorySnapshot(directory)

            for url in [package, file] {
                #expect(throws: CreateError.alreadyExists(url)) {
                    try BookPackage.create(at: url, title: "New")
                }
            }
            #expect(try DirectorySnapshot(directory) == before)
        }
    }

    @Test func aBookNeedsThePackageExtension() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel")
            #expect(throws: CreateError.missingPackageExtension(url)) {
                try BookPackage.create(at: url, title: "Novel")
            }
            let after = try DirectorySnapshot(directory)
            #expect(after.entries.isEmpty)
        }
    }

    @Test func aFailedCreateLeavesAPackageThatWontOpen() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            fileSystem.inject(.write("book.json"))
            #expect(throws: CreateError.self) {
                try BookPackage.create(at: url, title: "Novel", fileSystem: fileSystem)
            }
            let error = try #require(throws: LoadError.self) { try BookPackage.open(at: url) }
            #expect(error.problem == .bookMissing)
        }
    }
}
