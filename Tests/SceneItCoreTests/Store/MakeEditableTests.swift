import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// ADR 0024 and book format §10 Q7 through the store, as the app drives them.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MakeEditableTests {
    /// The `book.md.original-*.md` files in the package.
    private func originals(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
            .filter { $0.hasPrefix("book.md.original-") }.sorted().map { url.appending(path: $0) }
    }

    @Test func makeEditableFromTheAlertKeepsTheOriginalThenSavesTheRepairedBook() async throws {
        try await withTemporaryFolder { folder in
            let bytes = damaged(try draft(1))
            let url = try package(holding: bytes, in: folder)
            let fileSystem = FaultInjectingFileSystem(root: folder)
            let prompts = ScriptedPrompts([ReadOnlyChoice.makeEditable])
            let store = makeStore(
                in: folder, prompts: prompts, fileSystem: fileSystem, parseDefaults: fixedDefaults)

            #expect(await store.open(url) == .opened)
            #expect(prompts.titles == [ReadOnlyWording.readOnlyTitle])
            #expect(prompts.labels == [[ReadOnlyWording.keepReadOnly, ReadOnlyWording.makeEditable]])
            let book = try #require(store.current)
            #expect(book.isEditable)
            #expect(book.status == .unsaved, "the repaired book differs from the file")
            store.saveNow()
            await whenObserved { book.status == .saved }

            let original = try #require(try originals(url).first)
            #expect(try Data(contentsOf: original) == bytes)
            #expect(try bookOnDisk(url) == book.book)
            let calls = fileSystem.calls
            let kept = try #require(
                calls.firstIndex(of: .publish("Novel.sceneit/\(original.lastPathComponent)")))
            let locked = try #require(calls.firstIndex(of: .lock("Novel.sceneit/.lock")))
            let saved = try #require(calls.firstIndex(of: .writeTemporary("Novel.sceneit/book.md")))
            #expect(
                kept < locked && locked < saved, "the original is safe before the lock and the first save")
            #expect(await store.closeBook() == .left)
            #expect(try originals(url) == [original])
        }
    }

    @Test func keepReadOnlyRefusesEveryEditUntilMakeEditable() async throws {
        try await withTemporaryFolder { folder in
            let bytes = damaged(try draft(1))
            let url = try package(holding: bytes, in: folder)
            let fileSystem = FaultInjectingFileSystem(root: folder)
            let store = makeStore(in: folder, fileSystem: fileSystem, parseDefaults: fixedDefaults)

            guard case .openedReadOnly(.repairedOnOpen(let repair)) = await store.open(url) else {
                Issue.record("expected repairedOnOpen")
                return
            }
            #expect(!repair.newEntries.isEmpty)
            let book = try #require(store.current)
            #expect(!book.isEditable)
            #expect(StoreWording.status(book.status) == "Read only")
            let before = book.book
            let scene = try #require(before.scenes.first?.id)
            book.replaceBody(of: scene, with: [[Run("Not allowed")]])
            #expect(book.addScene(after: nil) == nil)
            store.saveNow()
            #expect(book.book == before)
            #expect(
                fileSystem.calls.filter(\.isMutation).isEmpty,
                "a read-only book writes nothing, not even .lock")

            #expect(await store.makeEditable() == .editable)
            #expect(book === store.current && book.isEditable)
            #expect(try originals(url).count == 1)
            #expect(try Data(contentsOf: url.layout.book) == bytes, "nothing saved yet")
            book.replaceBody(of: scene, with: [[Run("Now allowed")]])
            store.saveNow()
            await whenObserved { book.status == .saved }
            #expect(try bookOnDisk(url).scenes.first?.body == [[Run("Now allowed")]])
            #expect(await store.makeEditable() == .notRepaired, "it's editable already")
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func makeEditableFromTheBannerOrMenuAsksFirst() async throws {
        try await withTemporaryFolder { folder in
            let bytes = damaged(try draft(1))
            let url = try package(holding: bytes, in: folder)
            let prompts = ScriptedPrompts([ReadOnlyChoice.keepReadOnly, ReadOnlyChoice.keepReadOnly])
            let store = makeStore(in: folder, prompts: prompts, parseDefaults: fixedDefaults)
            guard case .openedReadOnly(.repairedOnOpen) = await store.open(url) else {
                Issue.record("expected repairedOnOpen")
                return
            }
            #expect(await store.confirmMakeEditable() == .keptReadOnly)
            #expect(prompts.titles.last == ReadOnlyWording.makeEditableTitle)
            #expect(prompts.labels.last == [ReadOnlyWording.keepReadOnly, ReadOnlyWording.makeEditable])
            #expect(store.current?.canBeMadeEditable == true)
            #expect(try originals(url).isEmpty, "nothing kept until the writer confirms")
            #expect(try Data(contentsOf: url.layout.book) == bytes, "book.md untouched")

            prompts.answer([ReadOnlyChoice.makeEditable])
            #expect(await store.confirmMakeEditable() == .editable)
            #expect(store.current?.isEditable == true)
            #expect(try originals(url).count == 1)
            let asked = prompts.titles.count
            #expect(await store.confirmMakeEditable() == .notRepaired)
            #expect(prompts.titles.count == asked, "no question once it's editable")
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func aNewerFormatStaysReadOnly() async throws {
        try await withTemporaryFolder { folder in
            let url = try package(holding: Data("---\ntitle: Later\nformat: 3\n---\n".utf8), in: folder)
            let fileSystem = FaultInjectingFileSystem(root: folder)
            let prompts = ScriptedPrompts([ReadOnlyChoice.makeEditable])
            let store = makeStore(in: folder, prompts: prompts, fileSystem: fileSystem)

            #expect(await store.open(url) == .openedReadOnly(.newerFormat(FormatVersion(3))))
            #expect(prompts.labels == [[ReadOnlyWording.keepReadOnly]])
            #expect(await store.makeEditable() == .notRepaired)
            #expect(store.current?.isEditable == false)
            #expect(fileSystem.calls.filter(\.isMutation).isEmpty)
            #expect(try originals(url).isEmpty)
        }
    }

    @Test func whenTheOriginalCantBeKeptNothingChanges() async throws {
        try await withTemporaryFolder { folder in
            let bytes = damaged(try draft(1))
            let url = try package(holding: bytes, in: folder)
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            guard case .openedReadOnly(.repairedOnOpen) = await store.open(url) else {
                Issue.record("expected repairedOnOpen")
                return
            }
            let path = url.path(percentEncoded: false)
            #expect(chmod(path, 0o555) == 0)
            defer { chmod(path, 0o755) }

            guard case .failed = await store.makeEditable() else {
                Issue.record("expected a failure")
                return
            }
            #expect(prompts.notices.map(\.title) == ["Scene It couldn't make the book editable."])
            #expect(store.current?.isEditable == false)
            #expect(try originals(url).isEmpty)
            #expect(try Data(contentsOf: url.layout.book) == bytes)
        }
    }

    @Test func aBookLockedElsewhereKeepsTheOriginalButStaysReadOnly() async throws {
        try await withTemporaryFolder { folder in
            let url = try package(holding: damaged(try draft(1)), in: folder)
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            guard case .openedReadOnly(.repairedOnOpen) = await store.open(url) else {
                Issue.record("expected repairedOnOpen")
                return
            }
            let held = open(url.layout.lock.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            defer { close(held) }
            try #require(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0, "precondition: the lock was free")
            #expect(await store.makeEditable() == .readOnly(.openElsewhere))
            #expect(prompts.labels.last == [ReadOnlyWording.keepReadOnly])
            #expect(store.current?.isEditable == false)
            guard case .readOnly(.repairedOnOpen) = store.current?.status else {
                Issue.record("it can be made editable once the other copy closes")
                return
            }
            #expect(try originals(url).count == 1)
        }
    }

    @Test func theStoreSuppliesTheParseDefaults() async throws {
        try await withTemporaryFolder { folder in
            let url = try package(
                holding: Data("---\ntitle: T\nformat: 2\n---\n\n## Untimed\n".utf8), in: folder)
            let store = makeStore(in: folder, parseDefaults: fixedDefaults)
            await store.open(url)
            let scene = try #require(store.current?.book.scenes.first)
            #expect(scene.id == .lettered(0))
            #expect(scene.modified == openedAt)
        }
    }
}
