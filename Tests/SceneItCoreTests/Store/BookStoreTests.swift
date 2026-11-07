import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct BookStoreTests {
    @Test func anEditIsSavedByCmdSAndTheBookReopensTheSame() async throws {
        try await withTemporaryFolder { folder in
            let memory = TransientBookMemory()
            let store = makeStore(in: folder, memory: memory)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            #expect(book.status == .saved)
            let scene = try #require(book.addScene(after: nil))
            #expect(book.status == .saving, "adding a scene opens it, and a scene switch saves at once")
            await eventually { book.status == .saved }
            book.replaceBody(of: scene, with: [[Run("It was a dark and stormy night.")]])
            #expect(book.status == .unsaved)
            store.saveNow()
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url) == book.book)
            #expect(memory.lastSaved != nil)
            let snapshots = try FileManager.default.contentsOfDirectory(
                atPath: url.appending(path: "Backups").path(percentEncoded: false))
            #expect(snapshots.contains { $0.hasPrefix("book-") })

            let saved = book.book
            #expect(await store.prepareToQuit() == .left)
            #expect(store.current == nil)
            let relaunched = makeStore(in: folder, memory: memory)
            #expect(await relaunched.open(url) == .opened)
            #expect(relaunched.current?.book == saved)
            #expect(relaunched.current?.isEditable == true)
        }
    }

    @Test func typingIsSavedAfterTheIdleDelay() async throws {
        try await withTemporaryFolder { folder in
            let clock = ManualClock()
            let store = makeStore(in: folder, clock: clock)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            await eventually { book.status == .saved }
            book.replaceBody(of: scene, with: [[Run("First")]])
            clock.advance(by: .seconds(1))
            book.setTitle(of: scene, to: "The ferry")
            clock.advance(by: .seconds(1))
            #expect(book.status == .unsaved)
            clock.advance(by: .seconds(1))
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).scenes.first?.title == "The ferry")
        }
    }

    @Test func switchingScenesAndDeactivatingSaveAtOnce() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let first = try #require(book.write("One"))
            store.saveNow()
            await eventually { book.status == .saved }
            book.replaceBody(of: first, with: [[Run("One, revised")]])
            book.select(nil)
            #expect(book.openScene == nil)
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).scenes.first?.body == [[Run("One, revised")]])

            book.replaceBody(of: first, with: [[Run("One, again")]])
            store.appDeactivated()
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).scenes.first?.body == [[Run("One, again")]])
        }
    }

    @Test func anEditThatChangesNothingIsNotAnEdit() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let scene = try #require(book.write("Same"))
            store.saveNow()
            await eventually { book.status == .saved }
            let before = book.book
            book.replaceBody(of: scene, with: [[Run("Same")]])
            book.setTitle(of: SceneID(rawValue: "no such scene"), to: "Ignored")
            #expect(book.status == .saved)
            #expect(book.book == before)
        }
    }

    // MARK: ADR 0018

    @Test func keepMyVersionSavesMineAndKeepsTheirsAsBak1() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts([ExternalChangeChoice.keepMyVersion])
            let store = makeStore(in: folder, prompts: prompts)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            book.write("Mine")
            store.saveNow()
            await eventually { book.status == .saved }

            let theirs = try draft(7)
            try writeExternally(theirs, to: url)
            book.write("More of mine")
            store.saveNow()
            await eventually { book.status == .saved }

            #expect(prompts.titles == ["This book was changed by another program."])
            #expect(prompts.labels == [["Keep My Version", "Open Other Version"]])
            #expect(try bookOnDisk(url) == book.book)
            #expect(try bookOnDisk(url, file: "book.md.bak1") == theirs)
        }
    }

    @Test func openOtherVersionSavesMineAsACopyAndReopensTheirs() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts([ExternalChangeChoice.openOtherVersion])
            let store = makeStore(in: folder, prompts: prompts)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            book.write("Mine")
            store.saveNow()
            await eventually { book.status == .saved }

            let theirs = try draft(7)
            try writeExternally(theirs, to: url)
            book.write("More of mine")
            let mine = book.book
            store.saveNow()
            await eventually { store.current !== book && store.current != nil }

            let reopened = try #require(store.current)
            #expect(reopened.book == theirs)
            #expect(reopened.isEditable, "the old package released the lock before the reopen")
            let copy = folder.appending(path: "Novel (my edits).sceneit")
            #expect(try bookOnDisk(copy) == mine)
            #expect(try bookOnDisk(url) == theirs)
            #expect(store.recentBooks.map(\.canonicalPath) == [url.canonicalPath, copy.canonicalPath])
            #expect(book.status == .closed)
        }
    }

    @Test func aSecondOpenOtherVersionTakesTheNextFreeName() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts([ExternalChangeChoice.openOtherVersion])
            let store = makeStore(in: folder, prompts: prompts)
            let url = try await createBook("Novel", in: folder, store: store)
            try FileManager.default.createDirectory(
                at: folder.appending(path: "Novel (my edits).sceneit"), withIntermediateDirectories: false)
            let book = try #require(store.current)
            try writeExternally(try draft(7), to: url)
            book.write("Mine")
            let mine = book.book
            store.saveNow()
            await eventually { store.current !== book && store.current != nil }
            #expect(try bookOnDisk(folder.appending(path: "Novel (my edits 2).sceneit")) == mine)
        }
    }

    @Test func whileTheWriterDecidesTheStatusSaysChangedOnDisk() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            prompts.holding = true
            let store = makeStore(in: folder, prompts: prompts)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            try writeExternally(try draft(7), to: url)
            book.write("Mine")
            store.saveNow()
            await eventually { prompts.titles.count == 1 }
            guard case .changedOnDisk(.externallyModified(.changed)) = book.status else {
                Issue.record("status is \(book.status)")
                return
            }
            #expect(StoreWording.status(book.status) == "Changed on disk")
            prompts.releaseHeld()
            await eventually { book.status == .saved }
        }
    }

    @Test func myEditsNamesAreFileNamesAndFallBackToTheOriginal() {
        let original = URL(filePath: "/Books/Draft Two.sceneit")
        #expect(
            StoreWording.myEditsFileName(title: "Novel", original: original, attempt: 1)
                == "Novel (my edits).sceneit")
        #expect(
            StoreWording.myEditsFileName(title: "Novel", original: original, attempt: 3)
                == "Novel (my edits 3).sceneit")
        #expect(
            StoreWording.myEditsFileName(title: "A/B: C", original: original, attempt: 1)
                == "A-B- C (my edits).sceneit")
        #expect(
            StoreWording.myEditsFileName(title: " / ", original: original, attempt: 1)
                == "Draft Two (my edits).sceneit")
    }

    // MARK: ADR 0038: one book per process

    @Test func anotherBookIsRefusedUnreadAndTheWriterIsTold() async throws {
        try await withTemporaryFolder { folder in
            let other = try await createClosedBook("Other", in: folder)
            let broken = folder.appending(path: "Broken.sceneit")
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            book.write("Unsaved when the other book is asked for")

            #expect(await store.open(other) == .refused)
            #expect(await store.open(broken) == .refused)
            #expect(await store.open([url, other]) == .refused)

            #expect(store.current === book)
            #expect(book.isEditable)
            #expect(book.hasUnsavedEdits, "nothing was saved for a switch")
            #expect(
                prompts.notices == [
                    OneBookWording.refusal(of: [other], whileOpen: url),
                    OneBookWording.refusal(of: [broken], whileOpen: url),
                    OneBookWording.refusal(of: [other], whileOpen: url),
                ])
            #expect(prompts.titles.isEmpty, "only told, never asked")
            #expect(
                !FileManager.default.fileExists(
                    atPath: broken.appending(path: ".lock").path(percentEncoded: false)),
                "the refused book wasn't read")
            #expect(try BookPackage.open(at: other).editable != nil, "nor locked")
        }
    }

    @Test func noBookCanBeCreatedOnceOneIsOpen() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let second = folder.appending(path: "Second.sceneit", directoryHint: .isDirectory)

            #expect(await store.create(at: second) == .refused)
            #expect(store.current === book)
            #expect(!FileManager.default.fileExists(atPath: second.path(percentEncoded: false)))
            #expect(prompts.notices.isEmpty, "New Book is disabled, so there's nothing to explain")
        }
    }

    @Test func onceTheBookIsClosedNothingOpensAgain() async throws {
        try await withTemporaryFolder { folder in
            let other = try await createClosedBook("Other", in: folder)
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            let url = try await createBook("Novel", in: folder, store: store)
            #expect(await store.prepareToQuit() == .left)
            guard case .ended = store.session else {
                Issue.record("the session is \(store.session)")
                return
            }

            #expect(await store.open(url) == .refused)
            #expect(await store.open(other) == .refused)
            #expect(await store.create(at: folder.appending(path: "New.sceneit")) == .refused)
            #expect(store.current == nil)
            #expect(!store.isChoosing)
            #expect(prompts.notices.isEmpty, "quitting, so nobody is told")
        }
    }

    @Test func quittingFromTheStartStateEndsTheSession() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            #expect(store.isChoosing)
            #expect(await store.prepareToQuit() == .left)
            #expect(!store.isChoosing)
            #expect(await store.create(at: folder.appending(path: "New.sceneit")) == .refused)
        }
    }

    @Test func aBookThatWontLoadLeavesTheStartState() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            let broken = folder.appending(path: "Broken.sceneit")
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: broken.appending(path: "book.md"), withIntermediateDirectories: false)

            guard case .failed(let error) = await store.open(broken) else {
                Issue.record("the broken book opened")
                return
            }
            #expect(error.package.canonicalPath == broken.canonicalPath)
            #expect(store.isChoosing)
            #expect(prompts.notices.map(\.title) == ["Scene It couldn't open “Broken”."])
            #expect(!store.recentBooks.contains { $0.canonicalPath == broken.canonicalPath })
            #expect(
                !FileManager.default.fileExists(
                    atPath: broken.appending(path: ".lock").path(percentEncoded: false)))

            try await createBook("Good", in: folder, store: store)
            #expect(store.current != nil, "still choosing, so another book opens")
        }
    }

    @Test func openingTheOpenBookAgainDoesNothing() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            #expect(await store.open(url.appending(path: "../Novel.sceneit")) == .alreadyOpen)
            #expect(await store.open([url]) == .alreadyOpen)
            #expect(store.current === book)
            #expect(prompts.notices.isEmpty)
        }
    }

    @Test func openingTheOpenReadOnlyBookAgainDoesNothing() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Held.sceneit")
            let holder = try BookPackage.create(at: url, title: "Held")
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
            let book = try #require(store.current)

            #expect(await store.open(url) == .alreadyOpen)
            #expect(store.current === book)
            #expect(
                prompts.titles == [ReadOnlyWording.readOnlyTitle], "the read-only alert isn't asked again")
            _ = consume holder
        }
    }

    @Test func aNameCollisionIsRefusedAndTold() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            let url = folder.appending(path: "Taken.sceneit")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            #expect(await store.create(at: url) == .failed(.alreadyExists(url)))
            #expect(
                prompts.notices.map(\.title) == ["There's already something named “Taken.sceneit” there."])
            #expect(store.current == nil)
        }
    }

    // MARK: Read-only (ADR 0020)

    @Test func aReadOnlyBookNeverSaves() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Held.sceneit")
            let holder = try BookPackage.create(at: url, title: "Held")
            try #require(try holder.package.save(draft(1)) != .unchanged)
            let fileSystem = FaultInjectingFileSystem(root: folder)
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts, fileSystem: fileSystem)

            #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
            #expect(prompts.titles == [ReadOnlyWording.readOnlyTitle])
            #expect(prompts.labels == [[ReadOnlyWording.keepReadOnly]])
            let book = try #require(store.current)
            #expect(book.status == .readOnly(.openElsewhere))
            #expect(StoreWording.status(book.status) == "Read only")
            #expect(book.autosave == nil)

            let before = book.book
            let scene = try #require(before.scenes.first?.id)
            book.replaceBody(of: scene, with: [[Run("Not allowed")]])
            book.setTitle(of: scene, to: "Nope")
            #expect(book.addScene(after: nil) == nil)
            store.saveNow()
            store.appDeactivated()
            #expect(await store.prepareToQuit() == .left)
            #expect(book.book == before)
            #expect(
                fileSystem.calls.filter(\.isMutation) == [.lock("Held.sceneit/.lock")],
                "only the lock attempt")
            _ = consume holder
        }
    }

    @Test func openAnywayReopensForEditingDespiteTheRecordShown() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Shared.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: folder)
            fileSystem.override(locality: .network)
            _ = try BookPackage.create(at: url, title: "Shared", fileSystem: fileSystem)
            let other = LockRecord(
                host: "Other Mac", hostID: "OTHER", userID: 501, processID: 1,
                since: Date(timeIntervalSince1970: 1_800_000_000))
            try other.encoded().write(to: url.appending(path: ".lock"))
            let prompts = ScriptedPrompts([ReadOnlyChoice.openAnyway(other)])
            let store = makeStore(in: folder, prompts: prompts, fileSystem: fileSystem)

            #expect(await store.open(url) == .opened)
            #expect(prompts.labels == [[ReadOnlyWording.keepReadOnly, ReadOnlyWording.openAnyway]])
            #expect(store.current?.isEditable == true)
        }
    }

    /// The book read again for Open Anyway is the open book: one that won't load leaves it open,
    /// read-only, and in Recent Books.
    @Test func anOpenAnywayThatWontLoadKeepsTheReadOnlyBookAndItsRecentEntry() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Shared.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: folder)
            fileSystem.override(locality: .network)
            _ = try BookPackage.create(at: url, title: "Shared", fileSystem: fileSystem)
            let other = LockRecord(
                host: "Other Mac", hostID: "OTHER", userID: 501, processID: 1,
                since: Date(timeIntervalSince1970: 1_800_000_000))
            try other.encoded().write(to: url.appending(path: ".lock"))
            let prompts = ScriptedPrompts([ReadOnlyChoice.openAnyway(other)])
            prompts.holding = true
            let store = makeStore(in: folder, prompts: prompts, fileSystem: fileSystem)

            let opening = Task { await store.open(url) }
            await eventually { prompts.titles.count == 1 }
            let readOnly = try #require(store.current)
            try #require(!readOnly.isEditable, "precondition: read-only behind the alert")
            let book = url.appending(path: "book.md")
            try FileManager.default.removeItem(at: book)
            try FileManager.default.createDirectory(at: book, withIntermediateDirectories: false)
            prompts.releaseHeld()

            guard case .failed = await opening.value else {
                Issue.record("precondition: the book read again doesn't load")
                return
            }
            #expect(store.current === readOnly)
            #expect(store.recentBooks.map(\.canonicalPath) == [url.canonicalPath])
            #expect(prompts.notices.map(\.title) == ["Scene It couldn't open “Shared”."])
        }
    }

    // MARK: Quitting

    @Test func quittingSavesReleasesAndTerminates() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            book.write("Saved at quit")
            #expect(await store.prepareToQuit() == .left)
            #expect(store.current == nil)
            #expect(try bookOnDisk(url) == book.book)
            #expect(try BookPackage.open(at: url).editable != nil)
        }
    }

    @Test func quitAsksWhenSavingFailsAndHonoursEachChoice() async throws {
        try await withTemporaryFolder { folder in
            let fileSystem = FaultInjectingFileSystem(root: folder)
            let prompts = ScriptedPrompts([QuitAlertChoice.cancel])
            let store = makeStore(in: folder, prompts: prompts, fileSystem: fileSystem)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            book.write("Unsaved")
            fileSystem.inject(.fail(.writeTemporary("Novel.sceneit/book.md"), cause: .noSpace))

            #expect(await store.prepareToQuit() == .stayed)
            #expect(store.current === book)
            #expect(book.isEditable, "Cancel keeps the book open, and editable")
            #expect(prompts.labels == [["Retry", "Cancel", "Quit Anyway"]])

            prompts.answer([QuitAlertChoice.quitAnyway])
            #expect(await store.prepareToQuit() == .left)
            #expect(store.current == nil)
        }
    }

    @Test func quittingWhenTheSaveFindsAnExternalChangeAsksThenOffersTheChoice() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts([QuitAlertChoice.cancel, ExternalChangeChoice.keepMyVersion])
            let store = makeStore(in: folder, prompts: prompts)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            try writeExternally(try draft(3), to: url)
            book.write("Mine")

            #expect(await store.prepareToQuit() == .stayed)
            #expect(prompts.labels.first == ["Cancel", "Quit Anyway"])
            await eventually { book.status == .saved }
            #expect(prompts.labels.last == ["Keep My Version", "Open Other Version"])
            #expect(try bookOnDisk(url) == book.book)
            #expect(try bookOnDisk(url, file: "book.md.bak1") == draft(3))
        }
    }

    // MARK: Recent books

    @Test func reopeningTheLastBookForgetsOneThatIsGoneOrBroken() async throws {
        try await withTemporaryFolder { folder in
            let memory = TransientBookMemory()
            let gone = folder.appending(path: "Gone.sceneit")
            memory.recentBookPaths = [gone.canonicalPath]
            let prompts = ScriptedPrompts()
            var store = makeStore(in: folder, prompts: prompts, memory: memory)
            await store.reopenLastBook()
            #expect(store.current == nil)
            #expect(store.recentBooks.isEmpty)
            #expect(prompts.notices.isEmpty)

            let broken = folder.appending(path: "Broken.sceneit")
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
            memory.recentBookPaths = [broken.canonicalPath]
            store = makeStore(in: folder, prompts: prompts, memory: memory)
            await store.reopenLastBook()
            #expect(store.current == nil)
            #expect(memory.recentBookPaths.isEmpty)
            #expect(prompts.notices.count == 1)

            let good = try await createBook("Good", in: folder, store: store)
            #expect(await store.prepareToQuit() == .left)
            store = makeStore(in: folder, prompts: prompts, memory: memory)
            await store.reopenLastBook()
            #expect(store.current?.layout.root.canonicalPath == good.canonicalPath)
        }
    }

    @Test func recentBooksAreMostRecentFirstWithoutDuplicates() {
        let a = URL(filePath: "/Books/A.sceneit")
        let b = URL(filePath: "/Books/B.sceneit")
        var list = RecentBooks.remembering(a, in: [])
        list = RecentBooks.remembering(b, in: list)
        list = RecentBooks.remembering(URL(filePath: "/Books/./A.sceneit/"), in: list)
        #expect(list == ["/Books/A.sceneit", "/Books/B.sceneit"])
        #expect(RecentBooks.forgetting(b, in: list) == ["/Books/A.sceneit"])
        let many = (0..<20).reduce(into: [String]()) { list, index in
            list = RecentBooks.remembering(URL(filePath: "/Books/\(index).sceneit"), in: list)
        }
        #expect(many.count == RecentBooks.limit)
        #expect(many.first == "/Books/19.sceneit")
    }
}
