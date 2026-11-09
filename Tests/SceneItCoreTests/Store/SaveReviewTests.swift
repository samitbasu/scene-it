import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// Save Review… through the store (review format §7): the page is written where the reviewer
/// chose, through a write that's read back before it's renamed into place, and never over the
/// copy or into the review's own folder.
@MainActor
struct SaveReviewTests {
    static let day = CalendarDay(year: 2026, month: 11, day: 9)!

    /// A review of the TIDE copy with a comment on "ferry".
    static func openReview(in folder: URL, _ store: TestStore) async throws -> OpenBook<ManualClock> {
        #expect(await store.openReview(try ReviewStoreTests.copy(in: folder)) == .opened)
        let book = try #require(store.current)
        try #require(ReviewStoreTests.commentFerry(in: book, saying: "Which ferry?") != nil)
        return book
    }

    @Test func thePageIsWrittenWhereTheReviewerChose() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            let book = try await Self.openReview(in: folder, store)
            let copyBytes = try Data(contentsOf: folder.appending(path: "Tide.md"))
            guard case .review(let context) = book.document else {
                Issue.record("not a review")
                return
            }
            let destination = folder.appending(
                path: ReviewOutputWording.defaultFileName(copy: context.copyFile))
            #expect(destination.lastPathComponent == "Tide review.html")

            #expect(await store.saveReview(of: book, to: destination, on: Self.day) == .saved)

            let report = try #require(book.reviewReport(on: Self.day))
            let page = String(decoding: try Data(contentsOf: destination), as: UTF8.self)
            #expect(page == ReviewHTML.page(report, review: context.id))
            #expect(page.contains("data-item=\"s1/") && page.contains("Which ferry?"))
            #expect(
                try Data(contentsOf: folder.appending(path: "Tide.md")) == copyBytes, "the copy is untouched")
            #expect(prompts.notices.isEmpty)
            #expect(!Self.temporaryFiles(in: folder))
        }
    }

    @Test func anExistingPageIsReplaced() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let book = try await Self.openReview(in: folder, store)
            let destination = folder.appending(path: "Old review.HTML")
            try Data("an older page".utf8).write(to: destination)

            #expect(await store.saveReview(of: book, to: destination, on: Self.day) == .saved)

            #expect(
                String(decoding: try Data(contentsOf: destination), as: UTF8.self).hasPrefix(
                    "<!DOCTYPE html>"))
        }
    }

    @Test(arguments: ["Tide.md", "Tide.review.md", "Tide review.txt", "Tide review"])
    func onlyAPageNameIsWritten(_ name: String) async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            let book = try await Self.openReview(in: folder, store)
            let before = try Self.listing(folder)

            #expect(
                await store.saveReview(of: book, to: folder.appending(path: name), on: Self.day)
                    == .failed(.notAPage))

            #expect(try Self.listing(folder) == before)
            #expect(prompts.notices == [ReviewOutputWording.notice(for: .notAPage)])
        }
    }

    /// The copy under another name: a hard link to it, or a symbolic link, named as a page.
    @Test(arguments: [LinkKind.hard, .symbolic])
    func theCopyUnderAPageNameIsRefused(_ link: LinkKind) async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let book = try await Self.openReview(in: folder, store)
            let copy = folder.appending(path: "Tide.md")
            let copyBytes = try Data(contentsOf: copy)
            let destination = folder.appending(path: "Tide.html")
            switch link {
            case .hard: try FileManager.default.linkItem(at: copy, to: destination)
            case .symbolic:
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: copy)
            }

            #expect(
                await store.saveReview(of: book, to: destination, on: Self.day) == .failed(.reviewsOwnFile))

            #expect(try Data(contentsOf: copy) == copyBytes)
        }
    }

    enum LinkKind: CaseIterable, Sendable {
        case hard, symbolic
    }

    @Test func theReviewsOwnFolderIsRefused() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let book = try await Self.openReview(in: folder, store)
            let reviews = folder.appending(path: "Reviews", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: reviews, withIntermediateDirectories: true)
            let destination = folder.appending(path: "reviews/./x.html")

            #expect(
                await store.saveReview(of: book, to: destination, on: Self.day) == .failed(.reviewsOwnFile))

            #expect(!FileManager.default.fileExists(atPath: reviews.appending(path: "x.html").path))
        }
    }

    @Test func aReadOnlyPageIsLeftAlone() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let book = try await Self.openReview(in: folder, store)
            let destination = folder.appending(path: "Tide review.html")
            try Data("keep me".utf8).write(to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o444], ofItemAtPath: destination.path(percentEncoded: false))

            #expect(
                await store.saveReview(of: book, to: destination, on: Self.day)
                    == .failed(.destination(.writeProtected(.readOnly))))
            #expect(try Data(contentsOf: destination) == Data("keep me".utf8))
        }
    }

    @Test func aFolderAtTheDestinationIsRefused() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let book = try await Self.openReview(in: folder, store)
            let destination = folder.appending(path: "Tide review.html", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

            #expect(
                await store.saveReview(of: book, to: destination, on: Self.day)
                    == .failed(.destination(.notAFile)))
        }
    }

    /// The page is read back before it's renamed into place: a read that fails leaves the
    /// destination as it was.
    @Test func aPageThatDoesntReadBackLeavesTheDestinationAsItWas() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let fileSystem = FaultInjectingFileSystem(root: folder)
            let store = makeStore(in: folder, prompts: prompts, fileSystem: fileSystem)
            let book = try await Self.openReview(in: folder, store)
            let destination = folder.appending(path: "Tide review.html")
            try Data("the earlier page".utf8).write(to: destination)
            fileSystem.inject(.fail(.read("temporary Tide review.html"), cause: .io))
            fileSystem.clearCalls()

            let result = await store.saveReview(of: book, to: destination, on: Self.day)

            guard case .failed(.destination(.fileSystem(let error))) = result else {
                Issue.record("expected a file-system failure, got \(result)")
                return
            }
            #expect(error.cause == .io)
            #expect(
                fileSystem.calls.contains(.writeTemporary("Tide review.html")),
                "precondition: it got that far")
            #expect(!fileSystem.calls.contains(.move("temporary Tide review.html", over: "Tide review.html")))
            #expect(try Data(contentsOf: destination) == Data("the earlier page".utf8))
            #expect(!Self.temporaryFiles(in: folder))
            #expect(prompts.notices.map(\.title) == [ReviewOutputWording.couldntSave])
        }
    }

    @Test func aReviewWithNothingInItSavesNothing() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            #expect(await store.openReview(try ReviewStoreTests.copy(in: folder)) == .opened)
            let book = try #require(store.current)
            #expect(!book.hasReviewReport)
            #expect(book.reviewReport(on: Self.day) == nil)
            let destination = folder.appending(path: "Tide review.html")

            #expect(await store.saveReview(of: book, to: destination, on: Self.day) == .unavailable)

            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(prompts.notices == [ReviewOutputWording.nothingToSave])
        }
    }

    @Test func aBookHasNoReview() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            #expect(!book.hasReviewReport && book.reviewReport(on: Self.day) == nil)
            let destination = folder.appending(path: "Novel review.html")

            #expect(await store.saveReview(of: book, to: destination, on: Self.day) == .unavailable)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    static func listing(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    static func temporaryFiles(in folder: URL) -> Bool {
        ((try? listing(folder)) ?? []).contains { $0.hasSuffix(".tmp") }
    }
}
