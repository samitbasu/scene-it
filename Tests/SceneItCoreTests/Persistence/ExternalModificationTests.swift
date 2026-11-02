import Foundation
import Testing

@testable import SceneItCore

@Suite struct ExternalModificationTests {
    enum Change: CaseIterable {
        case rewritten, touched, replacedWithIdenticalBytes, removed
    }

    @Test(arguments: Change.allCases)
    func aSaveRefusesToOverwriteAnExternalChange(_ change: Change) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            var package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let book = url.layout.book
            switch change {
            case .rewritten:
                try encoded(draft(7)).write(to: book)
            case .touched:
                let later = Date.now.addingTimeInterval(60)
                try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: book.path())
            case .replacedWithIdenticalBytes:
                let bytes = try Data(contentsOf: book)
                try FileManager.default.removeItem(at: book)
                try bytes.write(to: book)
            case .removed:
                try FileManager.default.removeItem(at: book)
            }
            let before = try DirectorySnapshot(url)

            #expect(throws: SaveError.externallyModified) { try package.save(draft(9)) }
            #expect(throws: SaveError.externallyModified) { try package.save(draft(0)) }
            #expect(try DirectorySnapshot(url) == before)
        }
    }

    @Test func reopeningAfterAnExternalChangeSavesAgain() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            var package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            try encoded(draft(7)).write(to: url.layout.book)
            #expect(throws: SaveError.externallyModified) { try package.save(draft(9)) }

            var reopened = try BookPackage.open(at: url)
            #expect(reopened.book == (try draft(7)))
            #expect(try reopened.package.save(draft(9)) == .saved)
            try expectStandardLayout(url.layout, book: draft(9), backups: [draft(7), draft(1), draft(2)])
        }
    }
}
