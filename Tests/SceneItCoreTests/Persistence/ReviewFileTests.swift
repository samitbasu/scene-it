import Foundation
import Testing

@testable import SceneItCore

/// The review file on disk (ADR 0042, review format §4, §9 Q9): finding a copy's review,
/// creating it at the first save that has something to keep, saving with verification and
/// rotation, the lock, read-only damaged reviews and Make Editable, and a copy that's never
/// written.
struct ReviewFileTests {
    static let opened = Timestamp(secondsSince1970: 1_800_000_000, offset: .zero)

    /// A folder with the TIDE copy as `Tide.md`, and a reviews folder beside it.
    struct Fixture {
        let folder: URL
        let copy: URL
        let reviews: ReviewsFolder

        init(_ root: URL) throws {
            folder = root.appending(path: "Mail", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            copy = folder.appending(path: "Tide.md")
            try Data(ReviewFormatTests.tide.utf8).write(to: copy)
            reviews = ReviewsFolder(root: root.appending(path: "Reviews", directoryHint: .isDirectory))
        }

        func open(_ url: URL? = nil) throws -> LoadedReview {
            var count = 0
            return try ReviewFile.open(
                url ?? copy, reviews: reviews, opened: ReviewFileTests.opened,
                freshID: {
                    count += 1
                    return ReviewID(rawValue: "review-\(count)")
                }, fileSystem: LocalFileSystem(), opener: .current)
        }

        var listing: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
                .sorted()
        }

        func text(_ name: String) throws -> String {
            try String(decoding: Data(contentsOf: folder.appending(path: name)), as: UTF8.self)
        }
    }

    static func editable(_ loaded: LoadedReview) throws -> ReviewFile {
        guard case .editing(let file) = loaded.access else {
            Issue.record("expected an editable review, got \(loaded.access)")
            throw CancellationError()
        }
        return file
    }

    /// The review with a note on Dawn.
    static func noted(_ loaded: LoadedReview, _ note: String = "Lovely.") -> Review {
        var book = loaded.book
        book.scenes[0].notes = [[Run(note)]]
        return loaded.context.review(of: book)
    }

    @Test func aCopyWithNoReviewOpensANewOneAndWritesNothingUntilThereIsSomethingToKeep() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let loaded = try fixture.open()
            let file = try Self.editable(loaded)
            #expect(loaded.book.scenes.map(\.id.rawValue) == ["s1", "s2"])
            #expect(loaded.otherReview == nil)
            #expect(try file.save(loaded.context.review(of: loaded.book)) == .unchanged)
            #expect(fixture.listing == ["Tide.md"])
            #expect(file.file == nil)

            guard case .saved = try file.save(Self.noted(loaded)) else {
                Issue.record("expected a save")
                return
            }
            #expect(fixture.listing == ["Tide.md", "Tide.review.md"])
            #expect(file.file?.lastPathComponent == "Tide.review.md")
            #expect(try fixture.text("Tide.review.md").contains("### Notes\nLovely."))
            #expect(
                try fixture.text("Tide.review.md").contains("copy: 01JDB2C7Q9X4M8T6V3N5R1K0PZ\nid: review-1"))
        }
    }

    @Test func reopeningTheCopyResumesItsReview() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            do {
                let loaded = try fixture.open()
                _ = try Self.editable(loaded).save(Self.noted(loaded))
            }
            let again = try fixture.open()
            _ = try Self.editable(again)
            #expect(again.context.id == ReviewID(rawValue: "review-1"))
            #expect(again.book.scenes[0].notes == [[Run("Lovely.")]])
        }
    }

    @Test func theCopyIsNeverWrittenAndBackupsGoToTheReviewsFolder() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let original = try Data(contentsOf: fixture.copy)
            let loaded = try fixture.open()
            let file = try Self.editable(loaded)
            for note in ["One.", "Two.", "Three.", "Four.", "Five."] {
                _ = try file.save(Self.noted(loaded, note))
            }
            #expect(try Data(contentsOf: fixture.copy) == original)
            #expect(fixture.listing == ["Tide.md", "Tide.review.md"])
            let folder = fixture.reviews.folder(for: loaded.context.id)
            let side = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
                .sorted()
            #expect(side == [".lock", "review.md.bak1", "review.md.bak2", "review.md.bak3"])
            #expect(
                try String(
                    decoding: Data(contentsOf: folder.appending(path: "review.md.bak1")), as: UTF8.self
                )
                .contains("Four."))
        }
    }

    @Test func aReviewIsLockedWhileItsOpenForEditing() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let first = try fixture.open()
            _ = try Self.editable(first).save(Self.noted(first))
            let second = try fixture.open()
            guard case .readOnly(.openElsewhere) = second.access else {
                Issue.record("expected the second open to be read-only, got \(second.access)")
                return
            }
            #expect(second.book.scenes[0].notes == [[Run("Lovely.")]])
        }
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            do {
                let first = try fixture.open()
                _ = try Self.editable(first).save(Self.noted(first))
            }
            _ = try Self.editable(try fixture.open())
        }
    }

    @Test func aSecondReviewOfOneCopyIsLockedApartFromTheFirst() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let first = try fixture.open()
            let second = try fixture.open()
            #expect(first.context.id == second.context.id, "precondition: the fixture's ids repeat")
            _ = try Self.editable(first)
            guard case .readOnly(.openElsewhere) = second.access else {
                Issue.record("one review id, one writer")
                return
            }
        }
    }

    @Test func aDamagedReviewOpensReadOnlyAndMakeEditableKeepsItsOriginalInTheReviewsFolder() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let damaged =
                ReviewFormatTests.fm + "\n\n## Dawn\nid: s1\n\n### Comments\n- c1 | red | nonsense\n"
            let reviewFile = fixture.folder.appending(path: "Tide.review.md")
            try Data(damaged.utf8).write(to: reviewFile)
            let loaded = try fixture.open()
            guard case .readOnly(.repairedOnOpen(let repair)) = loaded.access else {
                Issue.record("expected a repaired, read-only review, got \(loaded.access)")
                return
            }
            #expect(repair.newEntries.map(\.tag) == [.comments])
            let folder = fixture.reviews.folder(for: loaded.context.id)
            #expect(
                !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)), "no lock taken")

            let kept = try ReviewFile.keepOriginal(
                of: repair, now: Date(timeIntervalSince1970: 1_800_000_000))
            #expect(kept.url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
            #expect(kept.url.lastPathComponent.hasPrefix("review.md.original-"))
            #expect(try Data(contentsOf: kept.url) == Data(damaged.utf8))
            let keptURL = kept.url
            guard
                case .editing(let file) = ReviewFile.edit(kept, loaded.context, fileSystem: LocalFileSystem())
            else {
                Issue.record("expected Make Editable to lock the review")
                return
            }
            guard case .saved = try file.save(loaded.context.review(of: loaded.book)) else {
                Issue.record("the repaired review replaces the damaged file")
                return
            }
            #expect(
                try fixture.text("Tide.review.md").contains(
                    "### Unparsed\n- [comments] - c1 | red | nonsense"))
            #expect(try Data(contentsOf: keptURL) == Data(damaged.utf8))
            #expect(fixture.listing == ["Tide.md", "Tide.review.md"])
        }
    }

    @Test func aReviewInANewerFormatOpensReadOnlyForGood() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            try Data(ReviewFormatTests.fm.replacingOccurrences(of: "format: 1", with: "format: 3").utf8)
                .write(to: fixture.folder.appending(path: "Tide.review.md"))
            guard case .readOnly(.newerReviewFormat(let format)) = try fixture.open().access else {
                Issue.record("expected a newer format")
                return
            }
            #expect(format == FormatVersion(3))
        }
    }

    @Test func aReviewOfAnotherCopyIsNeverOverwrittenAndTheNewOneGetsTheNextName() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let other =
                ReviewFormatTests.fm.replacingOccurrences(of: "01JDB2C7Q9X4M8T6V3N5R1K0PZ", with: "OTHER")
                + "\n\n### Notes\nOld.\n"
            try Data(other.utf8).write(to: fixture.folder.appending(path: "Tide.review.md"))
            let loaded = try fixture.open()
            #expect(loaded.otherReview?.lastPathComponent == "Tide.review.md")
            _ = try Self.editable(loaded).save(Self.noted(loaded))
            #expect(fixture.listing == ["Tide-2.review.md", "Tide.md", "Tide.review.md"])
            #expect(try fixture.text("Tide.review.md") == other)
            #expect(
                try fixture.open().book.scenes[0].notes == [[Run("Lovely.")]], "found again by its copy id")
        }
    }

    @Test func aRenamedCopyFindsItsReviewByTheExportID() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            do {
                let loaded = try fixture.open()
                _ = try Self.editable(loaded).save(Self.noted(loaded))
            }
            let renamed = fixture.folder.appending(path: "Renamed.md")
            try FileManager.default.moveItem(at: fixture.copy, to: renamed)
            let again = try fixture.open(renamed)
            #expect(again.book.scenes[0].notes == [[Run("Lovely.")]])
        }
    }

    @Test func aReviewFileOpenedDirectlyOpensWithItsCopy() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            do {
                let loaded = try fixture.open()
                _ = try Self.editable(loaded).save(Self.noted(loaded))
            }
            let again = try fixture.open(fixture.folder.appending(path: "Tide.review.md"))
            #expect(again.context.copyFile.lastPathComponent == "Tide.md")
            #expect(again.book.scenes[0].notes == [[Run("Lovely.")]])
        }
    }

    @Test func aReviewFileWithoutItsCopyDoesntOpen() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let review = fixture.folder.appending(path: "Lost.review.md")
            try Data(
                ReviewFormatTests.fm.replacingOccurrences(of: "01JDB2C7Q9X4M8T6V3N5R1K0PZ", with: "GONE").utf8
            )
            .write(to: review)
            #expect(throws: ReviewOpenError.copyNotFound(review: review)) { try fixture.open(review) }
        }
    }

    @Test func aFileThatIsntACopyIsRefusedAndNothingIsWritten() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let book = fixture.folder.appending(path: "book.md")
            try Data("---\ntitle: Tide\nformat: 2\n---\n".utf8).write(to: book)
            #expect(throws: ReviewOpenError.notAReviewCopy(book)) { try fixture.open(book) }
            let newer = fixture.folder.appending(path: "Newer.md")
            try Data(ReviewFormatTests.tide.replacingOccurrences(of: "format: 2", with: "format: 3").utf8)
                .write(to: newer)
            #expect(throws: ReviewOpenError.newerCopy(newer, FormatVersion(3))) { try fixture.open(newer) }
            #expect(fixture.listing == ["Newer.md", "Tide.md", "book.md"])
            #expect(!FileManager.default.fileExists(atPath: fixture.reviews.root.path(percentEncoded: false)))
        }
    }

    @Test func aReviewWithNoCopyLineNamedForTheCopyIsTakenAsItsReviewReadOnly() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            try Data("---\ntitle: Tide\nformat: 1\n---\n\n## Dawn\nid: s1\n\n### Notes\nKept.\n".utf8)
                .write(to: fixture.folder.appending(path: "Tide.review.md"))
            let loaded = try fixture.open()
            guard case .readOnly(.repairedOnOpen) = loaded.access else {
                Issue.record("expected the guessed review to open read-only")
                return
            }
            #expect(loaded.book.scenes[0].notes == [[Run("Kept.")]])
        }
    }
}
