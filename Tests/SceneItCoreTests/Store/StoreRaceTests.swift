import Dispatch
import Foundation
import Synchronization
import Testing

@testable import SceneItCore

/// Holds a file-system call (on the thread making it) until the test opens the gate, so the
/// test can act on the main actor while the store waits for the disk.
private final class Gate: Sendable {
    private let arrivals = Mutex(0)
    private let proceed = DispatchSemaphore(value: 0)

    /// Called by the blocked call.
    func pass() {
        arrivals.withLock { $0 += 1 }
        proceed.wait()
    }

    /// Records an issue, rather than hanging, if nothing arrives within 10 s.
    func waitForArrival(sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let arrived = arrivals.withLock { arrivals in
                guard arrivals > 0 else { return false }
                arrivals -= 1
                return true
            }
            if arrived { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("nothing reached the gate", sourceLocation: sourceLocation)
    }

    func open() {
        proceed.signal()
    }
}

private let copyName = "Novel (my edits).sceneit"

/// A saved book "Novel" whose `book.md` another program then replaced, with one scene.
@MainActor
private func changedBook(
    in folder: URL, prompts: ScriptedPrompts, fileSystem: FaultInjectingFileSystem
) async throws -> (TestStore, OpenBook<ManualClock>, SceneID, URL) {
    let store = makeStore(in: folder, prompts: prompts, fileSystem: fileSystem)
    let url = try await createBook("Novel", in: folder, store: store)
    let book = try #require(store.current)
    let scene = try #require(book.write("Before the change"))
    store.saveNow()
    await eventually { book.status == .saved }
    try writeExternally(try draft(7), to: url)
    return (store, book, scene, url)
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct StoreRaceTests {
    // MARK: B1: Open Other Version keeps everything typed while the copy is written

    @Test func typingWhileTheCopyIsCreatedReachesTheCopy() async throws {
        try await withTemporaryFolder { folder in
            let fileSystem = FaultInjectingFileSystem(root: folder)
            let prompts = ScriptedPrompts([ExternalChangeChoice.openOtherVersion])
            let (store, book, scene, _) = try await changedBook(
                in: folder, prompts: prompts, fileSystem: fileSystem)
            let gate = Gate()
            fileSystem.before(.createDirectory(copyName)) { gate.pass() }

            book.replaceBody(of: scene, with: [[Run("Mine")]])
            store.saveNow()
            await gate.waitForArrival()
            book.replaceBody(of: scene, with: [[Run("Typed while the copy was created")]])
            gate.open()
            await eventually { store.current !== book && store.current != nil }

            let copy = try bookOnDisk(folder.appending(path: copyName))
            #expect(copy == book.book)
            #expect(copy.scenes.first?.body == [[Run("Typed while the copy was created")]])
        }
    }

    @Test func typingWhileTheCopyIsSavedIsSavedAgain() async throws {
        try await withTemporaryFolder { folder in
            let fileSystem = FaultInjectingFileSystem(root: folder)
            let prompts = ScriptedPrompts([ExternalChangeChoice.openOtherVersion])
            let (store, book, scene, _) = try await changedBook(
                in: folder, prompts: prompts, fileSystem: fileSystem)
            let gate = Gate()
            fileSystem.before(.exchange("\(copyName)/book.md")) { gate.pass() }

            book.replaceBody(of: scene, with: [[Run("Mine")]])
            store.saveNow()
            await gate.waitForArrival()
            book.replaceBody(of: scene, with: [[Run("Typed while the copy was saved")]])
            gate.open()
            await eventually { store.current !== book && store.current != nil }

            let copy = try bookOnDisk(folder.appending(path: copyName))
            #expect(copy == book.book)
            #expect(copy.scenes.first?.body == [[Run("Typed while the copy was saved")]])
        }
    }

    @Test func endlessTypingIsRefusedOnlyForTheLastPass() async throws {
        try await withTemporaryFolder { folder in
            let fileSystem = FaultInjectingFileSystem(root: folder)
            let prompts = ScriptedPrompts([ExternalChangeChoice.openOtherVersion])
            let (store, book, scene, _) = try await changedBook(
                in: folder, prompts: prompts, fileSystem: fileSystem)
            let gate = Gate()
            @Sendable func holdEveryCopySave() {
                fileSystem.before(.exchange("\(copyName)/book.md")) {
                    gate.pass()
                    holdEveryCopySave()
                }
            }
            holdEveryCopySave()

            book.replaceBody(of: scene, with: [[Run("Mine")]])
            store.saveNow()
            for pass in 1...TestStore.copyPasses {
                await gate.waitForArrival()
                #expect(book.isEditable == (pass < TestStore.copyPasses))
                book.replaceBody(of: scene, with: [[Run("Pass \(pass)")]])
                gate.open()
            }
            await eventually { store.current !== book && store.current != nil }

            let copy = try bookOnDisk(folder.appending(path: copyName))
            #expect(copy == book.book)
            #expect(copy.scenes.first?.body == [[Run("Pass \(TestStore.copyPasses - 1)")]])
        }
    }

    @Test func aCopyThatCantBeSavedIsRemovedAndTheBookStaysOpen() async throws {
        try await withTemporaryFolder { folder in
            let fileSystem = FaultInjectingFileSystem(root: folder)
            let prompts = ScriptedPrompts([ExternalChangeChoice.openOtherVersion])
            let (store, book, scene, _) = try await changedBook(
                in: folder, prompts: prompts, fileSystem: fileSystem)
            fileSystem.inject(.fail(.exchange("\(copyName)/book.md"), cause: .noSpace))

            book.replaceBody(of: scene, with: [[Run("Mine")]])
            store.saveNow()
            await eventually { !prompts.notices.isEmpty }

            #expect(
                prompts.notices.map(\.title) == ["Scene It couldn't save your version as a separate book."])
            #expect(
                !FileManager.default.fileExists(
                    atPath: folder.appending(path: copyName).path(percentEncoded: false)))
            #expect(store.current === book)
            #expect(book.isEditable)
            guard case .changedOnDisk = book.status else {
                Issue.record("status is \(book.status)")
                return
            }
        }
    }

    /// An editor's setter can still fire on the old book after the store let go of it, before
    /// SwiftUI redraws. The old book must already refuse it, or the edit lands nowhere.
    @Test func typingAfterTheFinalCheckIsRefused() async throws {
        try await withTemporaryFolder { folder in
            let fileSystem = FaultInjectingFileSystem(root: folder)
            let prompts = ScriptedPrompts([ExternalChangeChoice.openOtherVersion])
            let (store, book, scene, _) = try await changedBook(
                in: folder, prompts: prompts, fileSystem: fileSystem)
            book.replaceBody(of: scene, with: [[Run("Mine")]])
            let lateTyping = Task { @MainActor in
                while store.current === book { await Task.yield() }
                let before = book.book
                book.replaceBody(of: scene, with: [[Run("Typed after the final check")]])
                return (accepted: book.book != before, editable: book.isEditable)
            }
            store.saveNow()
            let late = await lateTyping.value
            await eventually { store.current != nil }

            #expect(!late.accepted)
            #expect(!late.editable)
            #expect(book.status == .closed)
            let copy = try bookOnDisk(folder.appending(path: copyName))
            #expect(copy == book.book)
            #expect(copy.scenes.first?.body == [[Run("Mine")]])
        }
    }

    // MARK: S3: when the original can't be read, the copy is opened

    @Test func whenTheOriginalIsNotAFileMyVersionIsOpened() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts([ExternalChangeChoice.openOtherVersion])
            let store = makeStore(in: folder, prompts: prompts)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            book.write("Mine")
            store.saveNow()
            await eventually { book.status == .saved }
            try FileManager.default.removeItem(at: url.appending(path: "book.md"))
            try FileManager.default.createDirectory(
                at: url.appending(path: "book.md"), withIntermediateDirectories: false)

            book.write("More of mine")
            let mine = book.book
            store.saveNow()
            await eventually { store.current !== book && store.current != nil }

            #expect(prompts.labels.first == ["Open My Version"])
            let opened = try #require(store.current)
            #expect(opened.layout.root.canonicalPath == folder.appending(path: copyName).canonicalPath)
            #expect(opened.book == mine)
            #expect(opened.isEditable)
            #expect(prompts.notices.map(\.title) == ["Scene It opened your version."])
            #expect(!store.recentBooks.contains { $0.canonicalPath == url.canonicalPath })
        }
    }

    // MARK: S1: Close Anyway past a stuck save never blocks later operations

    @Test func closeAnywayPastAStuckSaveLeavesTheStoreUsable() async throws {
        try await withTemporaryFolder { folder in
            let fileSystem = FaultInjectingFileSystem(root: folder)
            let clock = ManualClock()
            let prompts = ScriptedPrompts([QuitAlertChoice.quitAnyway])
            let store = makeStore(in: folder, prompts: prompts, fileSystem: fileSystem, clock: clock)
            let second = try await createBook("Second", in: folder, store: store)
            try await createBook("First", in: folder, store: store)
            let book = try #require(store.current)
            let gate = Gate()
            fileSystem.before(.writeTemporary("First.sceneit/book.md")) { gate.pass() }
            book.write("Stuck")
            await gate.waitForArrival()

            async let switched = store.open(second)
            await eventually { book.autosave?.quitIsQueuedBehindASave == true }
            clock.advance(by: AutosavePolicy.quitGracePeriod)
            #expect(await switched == .opened)
            #expect(prompts.titles == ["Scene It is still saving your book."])
            #expect(prompts.labels == [["Wait", "Close Anyway"]])
            #expect(await store.prepareToQuit() == .left)
            gate.open()
        }
    }

    // MARK: S2: books asked for together

    @Test func ofSeveralBooksTheFirstOpensAndTheRestGoToRecentBooks() async throws {
        try await withTemporaryFolder { folder in
            let names = ["A", "B", "C"]
            let urls = names.map { folder.appending(path: "\($0).sceneit", directoryHint: .isDirectory) }
            for (name, url) in zip(names, urls) {
                _ = try BookPackage.create(at: url, title: name)
            }
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)

            await store.open(urls)
            #expect(store.current?.layout.root.canonicalPath == urls[0].canonicalPath)
            #expect(store.recentBooks.map(\.canonicalPath) == urls.map(\.canonicalPath))
            #expect(
                prompts.notices == [
                    Notice(
                        title: "Scene It opens one book at a time.",
                        message: "“A” is open. These books were added to Recent Books instead: “B”, “C”.")
                ])
        }
    }

    @Test func whenTheFirstOfSeveralFailsTheNoticeSaysNothingIsOpen() async throws {
        try await withTemporaryFolder { folder in
            let broken = folder.appending(path: "Broken.sceneit", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
            let other = folder.appending(path: "Other.sceneit", directoryHint: .isDirectory)
            _ = try BookPackage.create(at: other, title: "Other")
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)

            await store.open([broken, other])
            #expect(store.current == nil)
            #expect(store.recentBooks.map(\.canonicalPath) == [other.canonicalPath])
            #expect(
                prompts.notices.last?.message == "These books were added to Recent Books instead: “Other”.")
        }
    }
}
