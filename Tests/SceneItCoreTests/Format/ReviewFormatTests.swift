import Foundation
import Testing

@testable import SceneItCore

/// The review file (review format §3): the appendix's B cases, the round trip, and save
/// verification against the copy.
struct ReviewFormatTests {
    /// The appendix's TIDE copy.
    static let tide = """
        ---
        title: Tide
        format: 2
        export: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
        exported: 2026-11-03T10:15:00-08:00
        ---

        ## Dawn
        id: s1
        modified: 2026-11-02T09:00:00-08:00

        The ferry left at dawn.

        ## Dusk
        id: s2
        modified: 2026-11-02T09:00:00-08:00

        The gulls came home.

        """

    /// The appendix's FM.
    static let fm = """
        ---
        title: Tide
        format: 1
        copy: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
        id: 01JDD8WQ4K7M2N9P3R5S6T8V0X
        ---
        """

    static func received(_ text: String = tide) throws -> ReceivedCopy {
        try #require(ReceivedCopy(ReviewCopyFormat.parse(Data(text.utf8), opened: BookFormat.rereadTime)))
    }

    static func parse(_ text: String, against copy: ReceivedCopy? = nil) throws -> ParsedReview {
        var fresh = 0
        return ReviewFormat.parse(Data(text.utf8), against: try copy ?? received()) {
            defer { fresh += 1 }
            return ReviewID(rawValue: "id-A\(fresh)")
        }
    }

    static func text(_ review: Review) -> String {
        String(decoding: ReviewFormat.serialize(review), as: UTF8.self)
    }

    /// The case's canonical text, its entries' payloads, and that the canonical text is a fixed
    /// point that verifies.
    static func check(
        _ input: String, expected: String, newEntries: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let parsed = try parse(input)
        #expect(text(parsed.review) == expected, sourceLocation: sourceLocation)
        #expect(parsed.newEntries.map(\.description) == newEntries, sourceLocation: sourceLocation)
        let again = try parse(expected)
        #expect(again.newEntries.isEmpty, sourceLocation: sourceLocation)
        #expect(text(again.review) == expected, sourceLocation: sourceLocation)
        let verified = try ReviewFormat.verifiedSerialization(of: parsed.review, against: received())
        #expect(String(decoding: verified, as: UTF8.self) == expected, sourceLocation: sourceLocation)
    }

    static let dawn = SceneID(rawValue: "s1")
    static let dusk = SceneID(rawValue: "s2")

    // MARK: Appendix B

    @Test func b1CommentsAndADetachedOneAreCanonical() throws {
        let input =
            Self.fm + """


                ## Dawn
                id: s1

                ### Comments
                - c1 | red | 2026-11-04T09:12:00-08:00 | c4-9 | "ferry" | Which ferry?
                - c2 | gray | 2026-11-04T09:30:00-08:00 | detached | Too short?

                """
        try Self.check(input, expected: input, newEntries: [])
        let scene = try #require(try Self.parse(input).review.book.scene(Self.dawn))
        #expect(scene.comments.map(\.id.rawValue) == ["c1", "c2"])
        #expect(!scene.isDetached(CommentID(rawValue: "c1")))
        #expect(scene.isDetached(CommentID(rawValue: "c2")))
        #expect(scene.body.map(\.text) == ["The ferry left at dawn."])
    }

    @Test func b2AQuoteIsCheckedAgainstTheCopy() throws {
        let entry = #"- c1 | red | 2026-11-04T09:12:00-08:00 | c4-9 | "gulls" | Which gulls?"#
        try Self.check(
            Self.fm + "\n\n## Dawn\nid: s1\n\n### Comments\n\(entry)\n",
            expected: Self.fm + "\n\n## Dawn\nid: s1\n\n### Unparsed\n- [comments] \(entry)\n",
            newEntries: ["[comments] \(entry)"])
    }

    @Test func b3ANotesRangeIsE7() throws {
        let entry = #"- c1 | red | 2026-11-04T09:12:00-08:00 | notes c0-3 | "The" | Hm."#
        let parsed = try Self.parse(Self.fm + "\n\n## Dawn\nid: s1\n\n### Comments\n\(entry)\n")
        #expect(parsed.newEntries.map(\.description) == ["[comments] \(entry)"])
        let scene = try #require(parsed.review.book.scene(Self.dawn))
        #expect(
            BookFormat.reason(
                for: ErrorRef(owner: .scene(Self.dawn), index: 0, entry: scene.errors[0]),
                in: parsed.review.book)
                == .comment(.rangeBounds))
    }

    @Test func b4AnOrphanSectionKeepsItsLines() throws {
        try Self.check(
            Self.fm + """


                ## Noon
                id: s9

                ### Notes
                Too short.

                ## Dusk
                id: s2

                ### Notes
                Lovely.

                """,
            expected: Self.fm + """


                ### Unparsed
                - [line] ## Noon
                - [line] id: s9
                - [line] ### Notes
                - [line] Too short.
                - [notice] There's no scene with id s9 in this review copy, so that section's lines were kept as entries.

                ## Dusk
                id: s2

                ### Notes
                Lovely.

                """,
            newEntries: [
                "[line] ## Noon", "[line] id: s9", "[line] ### Notes", "[line] Too short.",
                "[notice] There's no scene with id s9 in this review copy, so that section's lines were kept as entries.",
            ])
    }

    @Test func b5ASectionWithoutAnID() throws {
        try Self.check(
            Self.fm + "\n\n## Dawn\n\n### Notes\nQuick.\n",
            expected: Self.fm + """


                ### Unparsed
                - [line] ## Dawn
                - [line] ### Notes
                - [line] Quick.
                - [notice] A scene section had no id, so its lines were kept as entries.

                """,
            newEntries: [
                "[line] ## Dawn", "[line] ### Notes", "[line] Quick.",
                "[notice] A scene section had no id, so its lines were kept as entries.",
            ])
    }

    @Test func b6SectionsAreMergedRetitledAndSortedSilently() throws {
        let comment = #"- c1 | red | 2026-11-04T09:12:00-08:00 | c4-9 | "ferry" | Which ferry?"#
        try Self.check(
            Self.fm + """


                ## Dusk (draft)
                id: s2

                ### Notes
                Lovely.

                ## Dawn
                id: s1

                ### Comments
                \(comment)

                ## Dawn again
                id: s1

                ### Notes
                Quick.

                """,
            expected: Self.fm + """


                ## Dawn
                id: s1

                ### Notes
                Quick.

                ### Comments
                \(comment)

                ## Dusk
                id: s2

                ### Notes
                Lovely.

                """,
            newEntries: [])
    }

    @Test func b7MissingKeysAreNoticed() throws {
        try Self.check(
            "---\ntitle: Tide\n---\n\n## Dawn\nid: s1\n\n### Notes\nQuick.\n",
            expected: """
                ---
                title: Tide
                format: 1
                copy: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
                id: id-A0
                ---

                ### Unparsed
                - [notice] The file had no format line; it was read as format 1.
                - [notice] This review had no copy line, so it was taken to be the review of this copy, 01JDB2C7Q9X4M8T6V3N5R1K0PZ.
                - [notice] This review had no id, so it was given id-A0.

                ## Dawn
                id: s1

                ### Notes
                Quick.

                """,
            newEntries: [
                "[notice] The file had no format line; it was read as format 1.",
                "[notice] This review had no copy line, so it was taken to be the review of this copy, 01JDB2C7Q9X4M8T6V3N5R1K0PZ.",
                "[notice] This review had no id, so it was given id-A0.",
            ])
    }

    @Test func b8BodyLinesAndMarksAreLines() throws {
        try Self.check(
            Self.fm + "\n\n## Dawn\nid: s1\nLoved it.\n\n### Marks\n- color red | c0-3 | \"The\"\n",
            expected: Self.fm
                + "\n\n## Dawn\nid: s1\n\n### Unparsed\n- [line] Loved it.\n- [line] ### Marks\n- [line] - color red | c0-3 | \"The\"\n",
            newEntries: ["[line] Loved it.", "[line] ### Marks", "[line] - color red | c0-3 | \"The\""])
    }

    @Test func b9MetadataOtherThanTheID() throws {
        try Self.check(
            Self.fm + "\n\n## Dawn\nid: s1\nmodified: 2026-11-02T09:00:00-08:00\n\n### Notes\nQuick.\n",
            expected: Self.fm
                + "\n\n## Dawn\nid: s1\n\n### Notes\nQuick.\n\n### Unparsed\n- [metadata] modified: 2026-11-02T09:00:00-08:00\n",
            newEntries: ["[metadata] modified: 2026-11-02T09:00:00-08:00"])
    }

    @Test func b10AReviewerKeyIsUnknown() throws {
        let fm = Self.fm.replacingOccurrences(
            of: "id: 01JDD8WQ4K7M2N9P3R5S6T8V0X", with: "id: 01JDD8WQ4K7M2N9P3R5S6T8V0X\nreviewer: Jo Park")
        try Self.check(
            fm + "\n\n## Dawn\nid: s1\n\n### Notes\nQuick.\n",
            expected: Self.fm
                + "\n\n### Unparsed\n- [front matter] reviewer: Jo Park\n\n## Dawn\nid: s1\n\n### Notes\nQuick.\n",
            newEntries: ["[front matter] reviewer: Jo Park"])
    }

    // MARK: Beyond the appendix

    @Test func generalNotesAreThePreamblesNotes() throws {
        let input = Self.fm + "\n\n### Notes\nOverall: I couldn't put it down.\n\n<br>\n\nSecond *thought*.\n"
        try Self.check(input, expected: input, newEntries: [])
        let review = try Self.parse(input).review
        #expect(review.notes.map(\.text) == ["Overall: I couldn't put it down.", "", "Second thought."])
    }

    @Test func anEmptyFileIsAnEmptyReviewWithThreeNotices() throws {
        let parsed = try Self.parse("")
        #expect(!parsed.review.isEmpty)
        #expect(parsed.newEntries.count == 3)
        #expect(parsed.review.book.scenes.map(\.id) == [Self.dawn, Self.dusk])
        #expect(parsed.review.book.scenes.allSatisfy { $0.comments.isEmpty && $0.notes.isEmpty })
    }

    @Test func aNewerFormatIsNoticedAndMarked() throws {
        let parsed = try Self.parse(Self.fm.replacingOccurrences(of: "format: 1", with: "format: 2") + "\n")
        #expect(parsed.isNewerThanSupported)
        #expect(
            parsed.newEntries.map(\.payload) == [
                "The file says format 2; this version of Scene It reads review format 1."
            ])
    }

    @Test func anEmptyReviewOfTheCopyIsEmptyAndSerializesToTheFrontMatterAlone() throws {
        let copy = try Self.received()
        let review = Review(of: copy, id: ReviewID(rawValue: "01JDD8WQ4K7M2N9P3R5S6T8V0X"))
        #expect(review.isEmpty)
        #expect(Self.text(review) == Self.fm + "\n")
        #expect(review.book.scenes.map(\.title.text) == ["Dawn", "Dusk"])
    }

    @Test func aCommentMadeInMemoryRoundTrips() throws {
        let copy = try Self.received()
        var review = Review(of: copy, id: ReviewID(rawValue: "r1"))
        let comment = Comment(
            id: CommentID(rawValue: "c1"), color: .blue, text: "Which, though?",
            created: try #require(Timestamp("2026-11-04T09:12:00-08:00")))
        review.book.scenes[1].body = [
            [Run("The "), Run("gulls", comments: [comment.id]), Run(" came home.")]
        ]
        review.book.scenes[1].comments = [comment]
        review.book.scenes[0].notes = [[Run("Lovely", styles: [.italic])]]
        let bytes = try ReviewFormat.verifiedSerialization(of: review, against: copy)
        let reread = ReviewFormat.parse(bytes, against: copy) { ReviewID(rawValue: "unused") }
        #expect(reread.newEntries.isEmpty)
        #expect(reread.review == review)
        #expect(
            String(decoding: bytes, as: UTF8.self).contains(
                #"- c1 | blue | 2026-11-04T09:12:00-08:00 | c4-9 | "gulls" | Which, though?"#))
    }

    @Test func verificationRefusesAReviewWhoseTextDriftedFromTheCopy() throws {
        let copy = try Self.received()
        var review = Review(of: copy, id: ReviewID(rawValue: "r1"))
        let comment = Comment(
            id: CommentID(rawValue: "c1"), color: .red, text: "",
            created: try #require(Timestamp("2026-11-04T09:12:00-08:00")))
        review.book.scenes[0].body = [
            [Run("The "), Run("boat", comments: [comment.id]), Run(" left at dawn.")]
        ]
        review.book.scenes[0].comments = [comment]
        #expect(throws: VerificationFailure.self) {
            try ReviewFormat.verifiedSerialization(of: review, against: copy)
        }
    }

    @Test func verificationRefusesAReviewWithASceneTheCopyDoesntHave() throws {
        let copy = try Self.received()
        var review = Review(of: copy, id: ReviewID(rawValue: "r1"))
        review.book.scenes.append(
            BookScene(
                id: SceneID(rawValue: "s3"), modified: BookFormat.rereadTime, title: "Extra",
                notes: [[Run("Hi")]]))
        #expect(throws: VerificationFailure.self) {
            try ReviewFormat.verifiedSerialization(of: review, against: copy)
        }
    }

    @Test func aCopyWithMarksAndNotesIsReadAsItsStoryTextOnly() throws {
        let copy = try Self.received(
            Self.tide.replacingOccurrences(
                of: "The ferry left at dawn.\n",
                with:
                    "The ferry left at dawn.\n\n### Notes\nSecret.\n\n### Marks\n- color red | c0-3 | \"The\"\n"
            ))
        let dawn = try #require(copy.book.scene(Self.dawn))
        #expect(dawn.notes.isEmpty)
        #expect(dawn.body == [[Run("The ferry left at dawn.")]])
    }
}
