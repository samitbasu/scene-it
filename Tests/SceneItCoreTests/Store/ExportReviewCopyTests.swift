import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// Export as SceneIt… through the store (ADR 0029): a verified copy written atomically where the
/// writer chose, never inside the book, and nothing written when anything fails.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ExportReviewCopyTests {
    static let export = ExportID(rawValue: "01JDB2C7Q9X4M8T6V3N5R1K0PZ")
    static let exported = Timestamp("2026-11-03T10:15:00-08:00")!

    /// A book with two story scenes, notes and a tag on the first, and a scene in the Boneyard.
    private static func prepare(_ book: OpenBook<ManualClock>) throws -> [SceneID] {
        let first = try #require(book.addScene(after: nil))
        let second = try #require(book.addScene(after: first))
        book.replaceBody(of: first, with: [[Run("The ferry "), Run("left", styles: [.italic], color: .red)]])
        book.replaceNotes(of: first, with: [[Run("Private note.")]])
        #expect(book.addTag("secret-tag", to: first))
        book.replaceBody(of: second, with: [[Run("Arrival.")]])
        return [first, second]
    }

    private func export(
        _ store: TestStore, _ chosen: Set<SceneID>, to destination: URL
    ) async throws -> ExportResult {
        let book = try #require(store.current)
        return await store.exportReviewCopy(
            of: book, chosen: chosen, to: destination, export: Self.export, exported: Self.exported)
    }

    @Test func theCopyIsWrittenVerifiedAndTheBooksFilesAreUntouched() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let scenes = try Self.prepare(book)
            store.saveNow()
            await eventually { store.current?.status == .saved }
            let package = try DirectorySnapshot(url)
            let destination = folder.appending(path: "Novel.md")

            #expect(try await export(store, [scenes[1]], to: destination) == .exported)

            let parsed = ReviewCopyFormat.parse(try Data(contentsOf: destination), opened: Self.exported)
            #expect(parsed.recognition == .reviewCopy(Self.export, exported: Self.exported))
            #expect(parsed.parsed.newEntries.isEmpty)
            #expect(parsed.parsed.book.scenes.map(\.id) == [scenes[1]])
            #expect(try DirectorySnapshot(url) == package, "nothing in the book's package changed")
            #expect(prompts.notices.isEmpty)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
                    .sorted()
                    == ["Mirror", "Novel.md", "Novel.sceneit"].sorted(),
                "no temporary file is left behind")
        }
    }

    @Test func theUnsavedTextIsExportedWithoutBeingSaved() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let scenes = try Self.prepare(book)
            try #require(book.status != .saved, "precondition: unsaved edits")
            let destination = folder.appending(path: "Novel.md")

            #expect(try await export(store, Set(scenes), to: destination) == .exported)

            let text = String(decoding: try Data(contentsOf: destination), as: UTF8.self)
            #expect(text.contains("The ferry *left*"))
            #expect(!text.contains("Private note") && !text.contains("secret-tag") && !text.contains("red"))
            #expect(book.status != .saved, "exporting doesn't save the book")
        }
    }

    @Test func anExistingFileIsReplacedWhole() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            try await createBook("Novel", in: folder, store: store)
            let scenes = try Self.prepare(try #require(store.current))
            let destination = folder.appending(path: "Novel.md")
            try Data(String(repeating: "old text\n", count: 1000).utf8).write(to: destination)

            #expect(try await export(store, Set(scenes), to: destination) == .exported)

            let bytes = try Data(contentsOf: destination)
            #expect(ReviewCopyFormat.parse(bytes, opened: Self.exported).parsed.book.scenes.count == 2)
            #expect(!String(decoding: bytes, as: UTF8.self).contains("old text"))
        }
    }

    @Test(arguments: ["book.md", "Archive/copy.md", ""])
    func aDestinationInsideTheBookIsRefused(_ path: String) async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            let url = try await createBook("Novel", in: folder, store: store)
            let scenes = try Self.prepare(try #require(store.current))
            store.saveNow()
            await eventually { store.current?.status == .saved }
            let package = try DirectorySnapshot(url)
            let destination =
                path.isEmpty
                ? folder.appending(path: "./novel.SCENEIT") : url.appending(path: "x/../" + path)

            #expect(try await export(store, Set(scenes), to: destination) == .failed(.insideTheBook))

            #expect(try DirectorySnapshot(url) == package)
            #expect(prompts.notices == [ExportWording.notice(for: .insideTheBook)])
        }
    }

    @Test func aFolderAtTheDestinationIsRefused() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            try await createBook("Novel", in: folder, store: store)
            let scenes = try Self.prepare(try #require(store.current))
            let destination = folder.appending(path: "Novel.md", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

            #expect(try await export(store, Set(scenes), to: destination) == .failed(.notAFile))
            #expect(prompts.notices.map(\.title) == [ExportWording.couldntExport])
        }
    }

    @Test func aReadOnlyFileAtTheDestinationIsLeftAlone() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            try await createBook("Novel", in: folder, store: store)
            let scenes = try Self.prepare(try #require(store.current))
            let destination = folder.appending(path: "Novel.md")
            try Data("keep me".utf8).write(to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o444], ofItemAtPath: destination.path(percentEncoded: false))

            #expect(
                try await export(store, Set(scenes), to: destination) == .failed(.writeProtected(.readOnly)))
            #expect(try Data(contentsOf: destination) == Data("keep me".utf8))
        }
    }

    @Test func aWriteThatFailsLeavesTheDestinationAsItWas() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let fileSystem = FaultInjectingFileSystem(root: folder)
            let store = makeStore(in: folder, prompts: prompts, fileSystem: fileSystem)
            try await createBook("Novel", in: folder, store: store)
            let scenes = try Self.prepare(try #require(store.current))
            let destination = folder.appending(path: "Novel.md")
            try Data("the earlier copy".utf8).write(to: destination)
            fileSystem.inject(.fail(.move("temporary Novel.md", over: "Novel.md"), cause: .noSpace))
            fileSystem.clearCalls()

            let result = try await export(store, Set(scenes), to: destination)

            guard case .failed(.fileSystem(let error)) = result else {
                Issue.record("expected a file-system failure, got \(result)")
                return
            }
            #expect(error.cause == .noSpace)
            #expect(fileSystem.calls.contains(.writeTemporary("Novel.md")), "precondition: it got that far")
            #expect(try Data(contentsOf: destination) == Data("the earlier copy".utf8))
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
                    .sorted()
                    == ["Mirror", "Novel.md", "Novel.sceneit"].sorted(),
                "the temporary file was discarded")
            #expect(prompts.notices.map(\.message) == ["The disk is full. Nothing was written."])
        }
    }

    @Test func aBookNoLongerOpenExportsNothing() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let scenes = try Self.prepare(book)
            #expect(await store.closeBook() == .left)
            let destination = folder.appending(path: "Novel.md")

            let result = await store.exportReviewCopy(
                of: book, chosen: Set(scenes), to: destination, export: Self.export, exported: Self.exported)

            #expect(result == .unavailable)
            #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        }
    }

    @Test func theDefaultFileNameIsTheBooksTitle() {
        let package = URL(filePath: "/Books/Novel.sceneit")
        #expect(ExportWording.defaultFileName(title: "My Novel", package: package) == "My Novel.md")
        #expect(
            ExportWording.defaultFileName(title: "Either/Or: A Life", package: package)
                == "Either-Or- A Life.md")
        #expect(ExportWording.defaultFileName(title: " / ", package: package) == "Novel.md")
    }
}
