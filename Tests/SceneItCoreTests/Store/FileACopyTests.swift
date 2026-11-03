import Foundation
import Testing

@testable import SceneItCore

/// File a Copy through the store (PLAN §7.1) and the reconciliation that opening a book does
/// (PLAN §5.5).
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FileACopyTests {
    static let record = FilingRecord(
        filed: CalendarDay(year: 2026, month: 11, day: 1)!, tags: ["draft 4"], note: "Before the ending")

    static func filedCopy(_ number: Int, in url: URL) -> URL {
        PackageLayout(root: url).filedCopy(FiledCopyNumber(number)!)
    }

    static func indexOnDisk(_ url: URL) throws -> ArchiveIndex {
        ArchiveIndexFormat.parse(
            try Data(contentsOf: PackageLayout(root: url).archiveIndex), filed: { _ in record.filed }
        ).index
    }

    @Test func unsavedEditsAreSavedFirstAndTheCopyIsExactlyBookMd() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            book.write("The ferry left at dawn.")
            #expect(book.status != .saved, "precondition: there are unsaved edits")

            let result = await store.fileACopy(as: Self.record)

            guard case .filed(let outcome) = result else {
                Issue.record("expected a filed copy, got \(result)")
                return
            }
            #expect(outcome.isComplete)
            #expect(book.status == .saved)
            #expect(try bookOnDisk(url) == book.book)
            let copy = try Data(contentsOf: Self.filedCopy(1, in: url))
            #expect(copy == (try Data(contentsOf: url.appending(path: "book.md"))))
            #expect(book.archive == (try Self.indexOnDisk(url)))
            #expect(book.archive.copies.map(\.tags) == [["draft 4"]])
            #expect(prompts.notices.isEmpty, "a complete filing is confirmed by the toast, not an alert")
        }
    }

    @Test func twoQuickFilingsGetTwoNumbersAndBothEntries() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            book.write("One")
            async let first = store.fileACopy(as: Self.record)
            async let second = store.fileACopy(as: FilingRecord(filed: Self.record.filed, tags: ["second"]))
            let results = await [first, second]
            let numbers = results.compactMap { result -> Int? in
                if case .filed(let outcome) = result { outcome.number.value } else { nil }
            }
            #expect(Set(numbers) == [1, 2])
            #expect(try Self.indexOnDisk(url).copies.map(\.number.value) == [1, 2])
            #expect(Set(try Self.indexOnDisk(url).copies.map(\.tags)) == [["draft 4"], ["second"]])
        }
    }

    @Test func aReadOnlyBookCantFileACopy() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let url = try await createBook("Novel", in: folder, store: store)
            #expect(await store.closeBook() == .left)
            let holder = try #require(try BookPackage.open(at: url).editable)
            #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
            #expect(await store.fileACopy(as: Self.record) == .unavailable)
            #expect(
                try FileManager.default.contentsOfDirectory(
                    atPath: PackageLayout(root: url).archive.path(percentEncoded: false)) == ["index.md"])
            _ = holder
        }
    }

    @Test func aCopyThatCantBeLockedIsFiledAndTheWriterIsTold() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            let fileSystem = FaultInjectingFileSystem(root: url)
            let store = makeStore(in: folder, prompts: prompts, fileSystem: fileSystem)
            try await createBook("Novel", in: folder, store: store)
            fileSystem.inject(.fail(.makeImmutable("Archive/save0001.md"), cause: .unsupported))

            let result = await store.fileACopy(as: Self.record)

            guard case .filed(let outcome) = result else {
                Issue.record("expected a filed copy, got \(result)")
                return
            }
            #expect(outcome.lock != .locked)
            #expect(prompts.notices.map(\.title) == ["The copy was filed, but not everything worked."])
            #expect(store.current?.archive.copies.map(\.number.value) == [1])
        }
    }

    @Test func aFilingThatFailsFilesNothingAndTheWriterIsTold() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            let fileSystem = FaultInjectingFileSystem(root: url)
            let store = makeStore(in: folder, prompts: prompts, fileSystem: fileSystem)
            try await createBook("Novel", in: folder, store: store)
            fileSystem.inject(.fail(.writeTemporary("Archive/save0001.md"), cause: .noSpace))

            guard case .failed(.fileSystem(let error)) = await store.fileACopy(as: Self.record) else {
                Issue.record("expected the filing to fail")
                return
            }
            #expect(error.cause == .noSpace)
            #expect(prompts.notices.map(\.title) == ["Scene It couldn't file a copy."])
            #expect(store.current?.archive.copies.isEmpty == true)
        }
    }

    // MARK: Reconciliation on open

    @Test func openingReconcilesTheArchiveAndSavesTheIndex() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let url = try await createBook("Novel", in: folder, store: store)
            #expect(await store.closeBook() == .left)
            let layout = PackageLayout(root: url)
            try Data(contentsOf: layout.book).write(to: Self.filedCopy(4, in: url))
            try Data("---\nformat: 2\n---\n\n## save0002.md\nfiled: 2026-09-14\ntags: gone\n".utf8)
                .write(to: layout.archiveIndex)

            #expect(await store.open(url) == .opened)

            let book = try #require(store.current)
            #expect(book.archive.copies.map(\.number.value) == [4])
            #expect(
                book.archiveNotices == [
                    .droppedEntryWithoutFile(FiledCopyNumber(2)!), .listedWithoutEntry(FiledCopyNumber(4)!),
                ])
            #expect(try Self.indexOnDisk(url) == book.archive)
            #expect(book.archive.copies.first?.counts == FiledCopyCounts(book.book))
        }
    }

    @Test func openingReadOnlyReconcilesWithoutWriting() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let url = try await createBook("Novel", in: folder, store: store)
            #expect(await store.closeBook() == .left)
            let layout = PackageLayout(root: url)
            try Data(contentsOf: layout.book).write(to: Self.filedCopy(1, in: url))
            let index = try Data(contentsOf: layout.archiveIndex)
            let holder = try #require(try BookPackage.open(at: url).editable)

            #expect(await store.open(url) == .openedReadOnly(.openElsewhere))

            #expect(store.current?.archive.copies.map(\.number.value) == [1])
            #expect(try Data(contentsOf: layout.archiveIndex) == index)
            _ = holder
        }
    }
}
