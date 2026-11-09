import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// A File Cabinet card's + tag and × (PLAN §7.4): they rewrite only `Archive/index.md`, and
/// never the filed copy (PLAN §5.5, #32's acceptance).
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CabinetRecordTests {
    static let record = FileACopyTests.record

    /// A book with one filed copy, tagged `draft 4`.
    private func withFiledCopy(
        prompts: ScriptedPrompts = ScriptedPrompts(), faults: Faults = .none,
        _ body: (TestStore, OpenBook<ManualClock>, URL) async throws -> Void
    ) async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            let fileSystem: any FileSystem =
                switch faults {
                case .none: LocalFileSystem()
                case .injected(let injector): injector(folder)
                }
            let store = makeStore(in: folder, prompts: prompts, fileSystem: fileSystem)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            book.write("The ferry left at dawn.")
            guard case .filed(let outcome) = await store.fileACopy(of: book, as: Self.record),
                outcome.isComplete
            else {
                Issue.record("precondition: a copy is filed, locked and indexed")
                return
            }
            try await body(store, book, url)
        }
    }

    enum Faults {
        case none
        /// Made for the temporary folder the book is in.
        case injected((URL) -> FaultInjectingFileSystem)
    }

    @Test func addingAndRemovingATagRewritesOnlyTheIndex() async throws {
        try await withFiledCopy { store, book, url in
            let copy = FileACopyTests.filedCopy(1, in: url)
            let before = try FileFingerprint(copy)
            #expect(before.immutable, "precondition: the copy is locked")
            let bookBefore = try FileFingerprint(url.appending(path: "book.md"))

            #expect(await store.editRecord(of: book, .first, .addTag("beta readers")) == .edited)
            #expect(book.archive.copies.map(\.tags) == [["draft 4", "beta readers"]])
            #expect(try FileACopyTests.indexOnDisk(url) == book.archive)

            #expect(await store.editRecord(of: book, .first, .removeTag("DRAFT 4")) == .edited)
            #expect(book.archive.copies.map(\.tags) == [["beta readers"]], "any case")
            #expect(try FileACopyTests.indexOnDisk(url).copies.map(\.tags) == [["beta readers"]])
            #expect(book.archive.copies.map(\.note) == [Self.record.note], "the note stays")

            #expect(try FileFingerprint(copy) == before, "the filed copy's bytes, inode, time and lock")
            #expect(try FileFingerprint(url.appending(path: "book.md")) == bookBefore, "and the book's")
        }
    }

    @Test func aTagTheCopyHasInAnyCaseIsntAddedAgain() async throws {
        try await withFiledCopy { store, book, url in
            #expect(await store.editRecord(of: book, .first, .addTag("Draft 4")) == .edited)
            #expect(book.archive.copies.map(\.tags) == [["draft 4"]])
            let onDisk = try FileACopyTests.indexOnDisk(url)
            #expect(onDisk.copies.map(\.tags) == [["draft 4"]])
        }
    }

    @Test func anIndexThatCantBeWrittenIsLeftAndTheWriterIsTold() async throws {
        let prompts = ScriptedPrompts()
        var made: FaultInjectingFileSystem?
        let faults = Faults.injected { folder in
            let fileSystem = FaultInjectingFileSystem(root: folder)
            made = fileSystem
            return fileSystem
        }
        try await withFiledCopy(prompts: prompts, faults: faults) { store, book, url in
            let fileSystem = try #require(made)
            let shown = book.archive
            let onDisk = try Data(contentsOf: PackageLayout(root: url).archiveIndex)
            fileSystem.inject(FileACopyTests.indexWriteFails)

            let result = await store.editRecord(of: book, .first, .addTag("lost"))

            guard case .failed(.notWritten) = result else {
                Issue.record("expected the index write to fail, got \(result)")
                return
            }
            #expect(book.archive == shown, "the cards show what's on disk")
            #expect(try Data(contentsOf: PackageLayout(root: url).archiveIndex) == onDisk)
            #expect(prompts.notices.map(\.title) == ["The tag wasn't changed."])
        }
    }

    @Test func anIndexFromANewerVersionIsNeverRewritten() async throws {
        let prompts = ScriptedPrompts()
        try await withFiledCopy(prompts: prompts) { store, book, url in
            #expect(await store.closeBook() == .left)
            let newer = Data("---\nformat: 3\n---\n\n## save0001.md\nfiled: 2026-10-30\ntags: theirs\n".utf8)
            try newer.write(to: PackageLayout(root: url).archiveIndex)
            #expect(await store.open(url) == .opened)
            let reopened = try #require(store.current)
            #expect(!reopened.accepts(.archive), "the cards offer no + tag or ×")

            let result = await store.editRecord(of: reopened, .first, .addTag("mine"))

            #expect(result == .failed(.unavailable))
            #expect(try Data(contentsOf: PackageLayout(root: url).archiveIndex) == newer)
            _ = book
        }
    }

    /// `Archive.edit` itself, below the store's `accepts(.archive)`: an index a newer Scene It
    /// wrote is refused, and left byte for byte.
    @Test func archiveEditRefusesAnIndexFromANewerVersion() async throws {
        try await withFiledCopy { store, _, url in
            #expect(await store.closeBook() == .left)
            let layout = PackageLayout(root: url)
            let newer = Data("---\nformat: 3\n---\n\n## save0001.md\nfiled: 2026-10-30\ntags: theirs\n".utf8)
            try newer.write(to: layout.archiveIndex)
            let archive = Archive(layout: layout, fileSystem: LocalFileSystem())
            #expect {
                _ = try archive.edit(.first, .addTag("mine"), pending: [:])
            } throws: { error in
                if case .newerFormat? = error as? RecordEditFailure { true } else { false }
            }
            #expect(try Data(contentsOf: layout.archiveIndex) == newer)
        }
    }

    @Test func aReadOnlyBooksCardsChangeNothing() async throws {
        try await withFiledCopy { store, _, url in
            #expect(await store.closeBook() == .left)
            let holder = try #require(try BookPackage.open(at: url).editable)
            #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
            let book = try #require(store.current)
            try #require(book.archive.copies.count == 1, "precondition: the cabinet lists the copy")
            let index = try Data(contentsOf: PackageLayout(root: url).archiveIndex)
            #expect(!book.accepts(.archive))

            #expect(await store.editRecord(of: book, .first, .removeTag("draft 4")) == .failed(.unavailable))
            #expect(try Data(contentsOf: PackageLayout(root: url).archiveIndex) == index)
            _ = holder
        }
    }

    @Test func aBookClosedMeanwhileChangesNothing() async throws {
        try await withFiledCopy { store, book, url in
            let index = try Data(contentsOf: PackageLayout(root: url).archiveIndex)
            #expect(await store.closeBook() == .left)
            #expect(await store.editRecord(of: book, .first, .addTag("late")) == .failed(.unavailable))
            #expect(try Data(contentsOf: PackageLayout(root: url).archiveIndex) == index)
        }
    }

    @Test func aCopyTheIndexNoLongerListsIsRefused() async throws {
        try await withFiledCopy { store, book, url in
            let missing = try #require(FiledCopyNumber(7))
            #expect(await store.editRecord(of: book, missing, .addTag("x")) == .failed(.notInIndex))
            let onDisk = try FileACopyTests.indexOnDisk(url)
            #expect(onDisk.copies.map(\.tags) == [["draft 4"]])
        }
    }
}
