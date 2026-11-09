import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// Export to Word through the store (PLAN §10.2): the scene as it is now, written where the writer
/// chose through the write that's read back before it's renamed into place, from a read-only book
/// too, and never under a name that isn't a Word document's.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ExportToWordTests {
    /// The document's text, as macOS's `unzip` reads it.
    private static func documentXML(_ docx: URL) throws -> String {
        String(decoding: try Unzip.part(WordPackage.documentPart, of: Data(contentsOf: docx)), as: UTF8.self)
    }

    @Test func theUnsavedSceneIsWrittenWhereTheWriterChose() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let scene = try #require(book.write("The ferry left at dawn."))
            book.setTitle(of: scene, to: "The ferry")
            try #require(book.status != .saved, "precondition: unsaved edits")
            store.saveNow()
            await eventually { store.current?.status == .saved }
            book.replaceBody(of: scene, with: [[Run("The ferry left at "), Run("dusk", styles: [.italic])]])
            let package = try DirectorySnapshot(url)
            let name = WordExportWording.defaultFileName(
                scene: try #require(book.book.scene(scene)), package: url)
            #expect(name == "The ferry.docx")
            let destination = folder.appending(path: name)

            #expect(await store.exportToWord(of: book, scene: scene, to: destination) == .exported)

            let xml = try Self.documentXML(destination)
            #expect(xml.contains(">dusk<") && !xml.contains("dawn"), "the scene as it is now, unsaved")
            #expect(try DirectorySnapshot(url) == package, "nothing in the book's package changed")
            #expect(book.status != .saved, "exporting doesn't save the book")
            #expect(prompts.notices.isEmpty)
            let listing = try FileManager.default.contentsOfDirectory(
                atPath: folder.path(percentEncoded: false))
            #expect(
                listing.filter { TemporaryFile.destination(ofName: $0).map(String.init) == name }.isEmpty,
                "no temporary file is left behind: \(listing)")
        }
    }

    @Test func aReadOnlyBookExports() async throws {
        try await withTemporaryFolder { folder in
            let damaged = DeleteFromBoneyardTests.text.replacingOccurrences(
                of: "id: ferry", with: "id: ferry boat")
            let url = try package(holding: Data(damaged.utf8), in: folder)
            let store = makeStore(
                in: folder, prompts: ScriptedPrompts([ReadOnlyChoice.keepReadOnly]),
                parseDefaults: fixedDefaults)
            _ = await store.open(url)
            let book = try #require(store.current)
            try #require(!book.isEditable, "precondition: a repaired book opens read-only")
            let scene = try #require(book.book.scenes.first?.id)
            let destination = folder.appending(path: "Ferry.docx")

            #expect(await store.exportToWord(of: book, scene: scene, to: destination) == .exported)

            #expect(try Self.documentXML(destination).contains("Mara took the ferry."))
            #expect(await store.closeBook() == .left)
        }
    }

    @Test(arguments: ["Ferry.md", "Ferry.doc", "Ferry"])
    func onlyAWordDocumentsNameIsWritten(_ name: String) async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let scene = try #require(book.write("Text."))

            #expect(
                await store.exportToWord(of: book, scene: scene, to: folder.appending(path: name))
                    == .failed(.notAWordDocument))

            #expect(
                !FileManager.default.fileExists(
                    atPath: folder.appending(path: name).path(percentEncoded: false)))
            #expect(prompts.notices == [WordExportWording.notice(for: .notAWordDocument)])
        }
    }

    @Test func aReadOnlyFileAtTheDestinationIsLeftAlone() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let scene = try #require(book.write("Text."))
            let destination = folder.appending(path: "Ferry.DOCX")
            try Data("keep me".utf8).write(to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o444], ofItemAtPath: destination.path(percentEncoded: false))

            #expect(
                await store.exportToWord(of: book, scene: scene, to: destination)
                    == .failed(.destination(.writeProtected(.readOnly))))
            #expect(try Data(contentsOf: destination) == Data("keep me".utf8))
        }
    }

    @Test func aSceneNoLongerThereExportsNothing() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let destination = folder.appending(path: "Ferry.docx")

            #expect(
                await store.exportToWord(of: book, scene: SceneID(rawValue: "gone"), to: destination)
                    == .unavailable)

            #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
            #expect(prompts.notices == [WordExportWording.sceneClosed])
        }
    }

    @Test func theDefaultFileNameIsTheScenesTitle() {
        let package = URL(filePath: "/Books/Novel.sceneit")
        func name(_ title: SceneTitle) -> String {
            WordExportWording.defaultFileName(
                scene: BookScene(
                    id: SceneID(rawValue: "s"), modified: Timestamp("2026-11-03T10:15:00-08:00")!,
                    title: title),
                package: package)
        }
        #expect(name("The ferry") == "The ferry.docx")
        #expect(name("") == "Untitled scene.docx")
        #expect(name("Either/or: a choice") == "Either-or- a choice.docx")
    }
}
