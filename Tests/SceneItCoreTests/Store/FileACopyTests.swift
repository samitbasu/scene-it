import Foundation
import SceneItTestSupport
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
            let message = try #require(prompts.notices.first?.message)
            #expect(message.contains("\u{201C}draft 4\u{201D}"), "the tags are quoted so they can be retyped")
            #expect(message.contains("\u{201C}Before the ending\u{201D}"))
        }
    }

    @Test func withNoBookOpenTheWriterIsToldNothingWasFiled() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            #expect(await store.fileACopy(as: Self.record) == .unavailable)
            #expect(prompts.notices.map(\.title) == ["Scene It couldn't file a copy."])
            #expect(prompts.notices.first?.message.contains("\u{201C}draft 4\u{201D}") == true)
        }
    }

    @Test func tagsAnIndexWriteLostAreRecordedByTheNextSave() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            let fileSystem = FaultInjectingFileSystem(root: url)
            let store = makeStore(in: folder, prompts: prompts, fileSystem: fileSystem)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            fileSystem.inject(.fail(.move("Archive/temporary index.md", over: "Archive/index.md")))

            guard case .filed(let outcome) = await store.fileACopy(as: Self.record) else {
                Issue.record("expected a filed copy")
                return
            }
            #expect(outcome.index != .updated(book.archive))
            #expect(book.pendingRecords == [FiledCopyNumber.first: Self.record])
            #expect(book.archive.copies.map(\.tags) == [["draft 4"]], "the cabinet shows what was typed")
            #expect(prompts.notices.first?.message.contains("\u{201C}draft 4\u{201D}") == true)

            book.write("Still failing")
            store.saveNow()
            await eventually { book.status == .saved }
            #expect(book.pendingRecords.count == 1, "kept while the index still can't be written")

            fileSystem.clearFault()
            book.write("And now it works")
            store.saveNow()
            await eventually { book.pendingRecords.isEmpty }
            let copy = try #require(try Self.indexOnDisk(url).copies.first)
            #expect([copy.tags, [copy.note]] == [["draft 4"], ["Before the ending"]])
            #expect(copy.filed == Self.record.filed)
        }
    }

    @Test func tagsAnIndexWriteLostAreRecordedByTheNextFiling() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            let fileSystem = FaultInjectingFileSystem(root: url)
            let store = makeStore(in: folder, fileSystem: fileSystem)
            try await createBook("Novel", in: folder, store: store)
            fileSystem.inject(.fail(.read("Archive/index.md"), cause: .permissionDenied))
            _ = await store.fileACopy(as: Self.record)
            fileSystem.clearFault()

            _ = await store.fileACopy(as: FilingRecord(filed: Self.record.filed, tags: ["second"]))

            #expect(try Self.indexOnDisk(url).copies.map(\.tags) == [["draft 4"], ["second"]])
            #expect(store.current?.pendingRecords.isEmpty == true)
        }
    }

    // MARK: Leaving with the dialog up

    /// A draft as the dialog leaves it: a chip, a tag still being typed, and a note.
    static func typedDraft() -> FilingDraft {
        var draft = FilingDraft(today: record.filed)
        draft.pendingTag = "draft 4"
        draft.commitPendingTag()
        draft.pendingTag = "half typ"
        draft.note = "Before the ending"
        return draft
    }

    static let quitTitle = "Quit without filing the copy?"
    static let closeTitle = "Close without filing the copy?"

    @Test func quittingWithTypedTextAsksAndCancelKeepsTheBookAndTheDialog() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts([UnfiledDraftChoice.cancel])
            let store = makeStore(in: folder, prompts: prompts)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            book.filingDraft = Self.typedDraft()

            #expect(await store.prepareToQuit() == .stayed)

            #expect(prompts.titles == [Self.quitTitle])
            #expect(prompts.labels == [["Cancel", "Quit Anyway"]], "Cancel first: the default")
            let alert = ArchiveWording.unfiledDraftAlert(Self.typedDraft().record, leaving: .quit)
            #expect(alert.message.hasPrefix("The tags and note you typed haven't been filed."))
            #expect(alert.message.contains("\u{201C}half typ\u{201D}"), "the tag being typed is quoted")
            #expect(alert.message.contains("\u{201C}Before the ending\u{201D}"))
            #expect(store.current === book)
            #expect(book.filingDraft == Self.typedDraft(), "the dialog keeps what was typed")
        }
    }

    @Test func quittingWithTypedTextAndQuitAnywayQuits() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts([UnfiledDraftChoice.leaveAnyway])
            let store = makeStore(in: folder, prompts: prompts)
            try await createBook("Novel", in: folder, store: store)
            store.current?.filingDraft = Self.typedDraft()

            #expect(await store.prepareToQuit() == .left)

            #expect(prompts.titles == [Self.quitTitle])
            #expect(store.current == nil)
        }
    }

    @Test(arguments: [UnfiledDraftChoice.cancel, .leaveAnyway])
    func closingTheBookWithTypedTextAsksOnce(_ choice: UnfiledDraftChoice) async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts([choice])
            let store = makeStore(in: folder, prompts: prompts)
            try await createBook("Novel", in: folder, store: store)
            store.current?.filingDraft = Self.typedDraft()

            let outcome = await store.closeBook()

            #expect(prompts.titles == [Self.closeTitle])
            #expect(prompts.labels == [["Cancel", "Close Anyway"]])
            #expect(outcome == (choice == .cancel ? .stayed : .left))
            #expect((store.current != nil) == (choice == .cancel))
        }
    }

    /// Choosing "… Anyway" loses the typed text only if the book is really left: when the leave
    /// then stops (a save fails and the writer cancels), the dialog still holds it.
    enum LeavePath: CaseIterable {
        case quit, close
    }

    @Test(arguments: LeavePath.allCases)
    func leaveAnywayThenStayingKeepsTheTypedText(_ path: LeavePath) async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts([UnfiledDraftChoice.leaveAnyway, QuitAlertChoice.cancel])
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            let fileSystem = FaultInjectingFileSystem(root: url)
            let store = makeStore(in: folder, prompts: prompts, fileSystem: fileSystem)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            book.filingDraft = Self.typedDraft()

            book.write("Unsaved, and the save will fail")
            fileSystem.inject(.fail(.writeTemporary("book.md")))
            let outcome = path == .quit ? await store.prepareToQuit() : await store.closeBook()
            #expect(outcome == .stayed)
            #expect(prompts.titles.count == 2, "asked about the dialog, then about the failed save")
            fileSystem.clearFault()

            #expect(store.current === book)
            #expect(book.filingDraft == Self.typedDraft(), "the dialog still holds what was typed")
        }
    }

    @Test func theLeavePromptSaysWhatWasTyped() throws {
        let day = Self.record.filed
        let tagsOnly = FilingRecord(filed: day, tags: ["draft 4"])
        let noteOnly = FilingRecord(filed: day, note: "Before the ending")
        let both = FilingRecord(filed: day, tags: ["draft 4"], note: "Before the ending")
        for (record, sentence) in [
            (tagsOnly, "The tags you typed haven't been filed."),
            (noteOnly, "The note you typed hasn't been filed."),
            (both, "The tags and note you typed haven't been filed."),
        ] {
            let message = ArchiveWording.unfiledDraftAlert(record, leaving: .quit).message
            #expect(message == sentence + ArchiveWording.typed(record), "\(sentence)")
        }
        var halfTyped = FilingDraft(today: day)
        halfTyped.pendingTag = "half typ"
        #expect(halfTyped.holdsTypedText)
        #expect(
            ArchiveWording.unfiledDraftAlert(halfTyped.record, leaving: .closeBook).message
                .hasPrefix("The tags you typed haven't been filed."), "a tag still being typed counts as tags"
        )
    }

    @Test func leavingWithAnEmptyDialogDoesntAsk() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            try await createBook("Novel", in: folder, store: store)
            var draft = FilingDraft(today: Self.record.filed)
            draft.pendingTag = "   "
            draft.filed = CalendarDay(year: 2020, month: 1, day: 1)!
            #expect(!draft.holdsTypedText, "precondition: blanks and the date aren't typed text")
            store.current?.filingDraft = draft

            #expect(await store.closeBook() == .left)
            try await createBook("Again", in: folder, store: store)
            store.current?.filingDraft = draft
            #expect(await store.prepareToQuit() == .left)

            #expect(prompts.titles.isEmpty)
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
            let kept = try FileManager.default.contentsOfDirectory(
                atPath: layout.archive.path(percentEncoded: false)
            )
            .filter { $0.hasPrefix("index.md.original-") }
            #expect(kept.count == 1, "the index was kept before its section was rewritten")
            #expect(
                book.archiveNotices == [
                    .keptEntryWithoutFile(FiledCopyNumber(2)!), .listedWithoutEntry(FiledCopyNumber(4)!),
                    .lockedUnlockedCopy(FiledCopyNumber(4)!),
                    .keptOriginalIndex(fileName: try #require(kept.first)),
                ])
            #expect(try isImmutable(Self.filedCopy(4, in: url)), "a copy left unlocked is locked")
            #expect(try Self.indexOnDisk(url) == book.archive)
            #expect(
                book.archive.errors.map(\.payload).contains("tags: gone"), "the gone entry's lines are kept")
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
