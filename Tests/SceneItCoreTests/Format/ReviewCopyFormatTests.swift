import Foundation
import Testing

@testable import SceneItCore

/// The review copy (review format §2): the projection Export as SceneIt… writes, its bytes, its
/// verification, and review-copy mode, which reads it back.
struct ReviewCopyFormatTests {
    static let export = ExportID(rawValue: "01JDB2C7Q9X4M8T6V3N5R1K0PZ")
    static let exported = Timestamp("2026-11-03T10:15:00-08:00")!

    static func copy(_ book: Book, _ chosen: Set<SceneID>) -> ReviewCopy {
        ReviewCopy(projecting: book, chosen: chosen, export: export, exported: exported)
    }

    static func text(_ copy: ReviewCopy) -> String {
        String(decoding: ReviewCopyFormat.serialize(copy), as: UTF8.self)
    }

    static func everyStoryScene(_ book: Book) -> Set<SceneID> {
        Set(book.scenes.map(\.id))
    }

    /// A book with something of everything the copy leaves out: tags, notes, comments, colors,
    /// highlights, error entries, a Boneyard and a deleted scene.
    static func richBook() throws -> Book {
        var book = try RichBook.make()
        book.deleted = [
            BookScene(
                id: SceneID(rawValue: "deleted-1"), modified: exported, title: "Deleted forever",
                body: [[Run("Never shown.")]])
        ]
        return book
    }

    // MARK: The worked example

    /// Review format §8.1, byte for byte.
    @Test func theWorkedExampleIsWrittenExactlyAsTheSpecShowsIt() throws {
        let ferry = BookScene(
            id: SceneID(rawValue: "01JCM9S346Q3D25VT4F5V37E3S"),
            modified: try #require(Timestamp("2026-11-02T09:00:00-08:00")), title: "The ferry",
            tags: ["opening"],
            body: [
                [
                    Run("The ferry left at dawn, and Mara watched the "),
                    Run("harbor lights", styles: [.italic], color: .purple),
                    Run(" go out one by one behind her.", highlight: .green),
                ],
                [Run("\"Don't look back,\" the deckhand said -- and she didn't.")],
            ],
            notes: [[Run("Is dawn too early?")]])
        let arrival = BookScene(
            id: SceneID(rawValue: "01JC3E28JT97KB6CQ643DZVMXX"),
            modified: try #require(Timestamp("2026-11-02T03:18:00-08:00")), title: "Arrival",
            body: [
                [Run("Nobody met her at the landing, which she had half expected and wholly dreaded.")],
                [
                    Run(
                        "At the top of the hill she stopped, set down the suitcase that had been her mother's, "
                            + "and looked for a long time at the house... it had been painted "),
                    Run("blue", styles: [.bold]),
                    Run("."),
                ],
            ])
        let skipped = BookScene(
            id: SceneID(rawValue: "skipped"), modified: Self.exported, title: "Not sent", body: [[Run("No.")]]
        )
        let book = Book(title: "My Novel", scenes: [ferry, skipped, arrival])

        let copy = Self.copy(book, [ferry.id, arrival.id])

        #expect(
            Self.text(copy) == """
                ---
                title: My Novel
                format: 2
                export: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
                exported: 2026-11-03T10:15:00-08:00
                ---

                ## The ferry
                id: 01JCM9S346Q3D25VT4F5V37E3S
                modified: 2026-11-02T09:00:00-08:00

                The ferry left at dawn, and Mara watched the *harbor lights* go out one by one behind her.

                "Don't look back," the deckhand said -- and she didn't.

                ## Arrival
                id: 01JC3E28JT97KB6CQ643DZVMXX
                modified: 2026-11-02T03:18:00-08:00

                Nobody met her at the landing, which she had half expected and wholly dreaded.

                At the top of the hill she stopped, set down the suitcase that had been her mother's, and looked for a long time at the house... it had been painted **blue**.

                """)
        #expect(try ReviewCopyFormat.verifiedSerialization(of: copy) == ReviewCopyFormat.serialize(copy))
    }

    // MARK: The projection

    @Test func theCopyHoldsTheChosenStoryScenesInStoryOrderAndNothingElse() throws {
        let book = try Self.richBook()
        let copy = Self.copy(book, Self.everyStoryScene(book))

        #expect(copy.book.title == book.title)
        #expect(copy.book.scenes.map(\.id) == book.scenes.map(\.id))
        #expect(copy.book.scenes.map(\.title) == book.scenes.map(\.title))
        #expect(copy.book.scenes.map(\.modified) == book.scenes.map(\.modified))
        #expect(copy.book.scenes.map { $0.body.map(\.text) } == book.scenes.map { $0.body.map(\.text) })
        #expect(copy.book.boneyard.isEmpty)
        #expect(copy.book.deleted.isEmpty)
        #expect(copy.book.errors.isEmpty)
        for scene in copy.book.scenes {
            #expect(
                scene.tags.isEmpty && scene.notes.isEmpty && scene.comments.isEmpty && scene.errors.isEmpty)
            for run in scene.body.flatMap(\.runs) {
                #expect(run.color == nil && run.highlight == nil && run.comments.isEmpty, "\(run)")
            }
        }
    }

    @Test func stylesAreKeptAndRunsThatThenMatchMerge() throws {
        let book = try Self.richBook()
        try #require(
            book.scenes[0].body[0].runs.count == 4, "precondition: the first paragraph has four runs")
        let copy = Self.copy(book, Self.everyStoryScene(book))
        let body = try #require(copy.book.scenes.first).body
        #expect(
            body[0].runs == [Run("He found the letter under the"), Run(" bench.", styles: [.italic])],
            "the comments are gone, so the three plain runs are one")
        #expect(body[1].runs.isEmpty, "an empty paragraph stays")
        #expect(
            body[2].runs.map(\.styles) == [[.bold], [.strike], [.bold, .italic, .strike], []],
            "bold, italic and strikethrough survive their colors and highlights")
    }

    @Test func nothingTheCopyLeavesOutReachesTheFile() throws {
        let book = try Self.richBook()
        let text = Self.text(Self.copy(book, Self.everyStoryScene(book).union(book.boneyard.map(\.id))))
        let excluded = [
            "### Notes", "### Comments", "### Marks", "### Unparsed", "tags:", "# Boneyard", "# Deleted",
            "opening", "Mara", "#hash", "Check the", "tide tables", "Overlaps the first", "Too early",
            "detached", "author: S. Basu", "mood: grim", "Something was repaired", "A cut scene", "Gone",
            "Why cut?", "Deleted forever", "Never shown",
            book.boneyard[0].id.rawValue, "deleted-1",
        ]
        for fragment in excluded {
            #expect(!text.contains(fragment), "\(fragment) leaked into the copy")
        }
        try #require(text.contains("He found the letter"), "precondition: the text itself is there")
    }

    @Test func aSubsetIsWrittenInStoryOrderWhateverOrderItWasChosenIn() throws {
        let scenes = (1...5).map { number in
            BookScene(
                id: SceneID(rawValue: "s\(number)"), modified: Self.exported,
                title: SceneTitle("Scene \(number)"),
                body: [[Run("Text \(number).")]])
        }
        let book = Book(
            title: "Five", scenes: scenes,
            boneyard: [scenes[0]].map { scene in
                var cut = scene
                cut.id = SceneID(rawValue: "cut")
                return cut
            })
        let chosen = Set(["s4", "s2", "cut", "missing"].map(SceneID.init(rawValue:)))

        let copy = Self.copy(book, chosen)

        #expect(copy.book.scenes.map(\.id.rawValue) == ["s2", "s4"])
        #expect(copy.book.boneyard.isEmpty, "a Boneyard scene is never exported, even if its id is chosen")
        let reread = ReviewCopyFormat.parse(
            try ReviewCopyFormat.verifiedSerialization(of: copy), opened: openedAt)
        #expect(reread.parsed.book.scenes.map(\.id.rawValue) == ["s2", "s4"])
    }

    @Test func choosingNothingWritesAValidCopyWithNoScenes() throws {
        let copy = Self.copy(try Self.richBook(), [])
        #expect(copy.book.scenes.isEmpty)
        let reread = ReviewCopyFormat.parse(
            try ReviewCopyFormat.verifiedSerialization(of: copy), opened: openedAt)
        #expect(reread.recognition == .reviewCopy(Self.export, exported: Self.exported))
    }

    // MARK: Round trips

    @Test func theRichBooksCopyReadsBackAsItselfInReviewCopyMode() throws {
        let book = try Self.richBook()
        let copy = Self.copy(book, Self.everyStoryScene(book))
        let bytes = try ReviewCopyFormat.verifiedSerialization(of: copy)
        let reread = ReviewCopyFormat.parse(bytes, opened: openedAt)
        #expect(reread.recognition == .reviewCopy(Self.export, exported: Self.exported))
        #expect(reread.parsed.newEntries.isEmpty)
        #expect(reread.parsed.book == copy.book)
        #expect(reread.parsed.declaredFormat == .current)
    }

    /// Formatting that's easy to get wrong in Markdown: nested and adjacent styles, styled
    /// spaces, characters that mean something to the format, and paragraphs that look like the
    /// format's own lines. Each must read back exactly.
    @Test(arguments: formattingEdgeCases)
    func formattingEdgeCasesReadBackExactly(_ body: [Paragraph]) throws {
        let scene = BookScene(
            id: SceneID(rawValue: "s1"), modified: Self.exported, title: "*Edge* _cases_", body: body)
        let copy = Self.copy(Book(title: "Edges: a # title", scenes: [scene]), [scene.id])
        let bytes = try ReviewCopyFormat.verifiedSerialization(of: copy)
        let reread = ReviewCopyFormat.parse(bytes, opened: openedAt)
        #expect(reread.parsed.book == copy.book)
        #expect(reread.parsed.newEntries.isEmpty)
    }

    static let formattingEdgeCases: [[Paragraph]] = [
        [[Run("all three", styles: [.bold, .italic, .strike])]],
        [
            [
                Run("bold", styles: [.bold]), Run("bold italic", styles: [.bold, .italic]),
                Run("italic", styles: [.italic]),
            ]
        ],
        [[Run("a "), Run(" spaced ", styles: [.bold]), Run(" b")]],
        [[Run(" ", styles: [.italic])]],
        [[Run("*not italic* _nor this_ ~~nor struck~~ \\ back\\slash")]],
        [[Run("# not a heading")], [Run("## nor this")], [Run("### Notes")], [Run("# Boneyard")]],
        [[Run("id: not-metadata")], [Run("modified: 2026-01-01T00:00:00+00:00")]],
        [[Run("- not an entry")], [Run("---")], [Run("tags: a, b")]],
        [[], [Run("between empty paragraphs")], []],
        [],
        [[Run("x", styles: [.strike]), Run("y", styles: [.strike, .bold]), Run("z", styles: [.strike])]],
        [[Run("trailing styled space ", styles: [.bold]), Run("then plain")]],
    ]

    @Test func anUntitledSceneAndAnEmptyBookTitleReadBack() throws {
        let scene = BookScene(
            id: SceneID(rawValue: "s1"), modified: Self.exported, title: "", body: [[Run("x")]])
        let copy = Self.copy(Book(title: "", scenes: [scene]), [scene.id])
        let reread = ReviewCopyFormat.parse(
            try ReviewCopyFormat.verifiedSerialization(of: copy), opened: openedAt)
        #expect(reread.parsed.book == copy.book)
    }

    @Test func eachExportGetsAFreshValidID() {
        var ids = IDGenerator.system
        let first = ids.exportID()
        let second = ids.exportID()
        #expect(first != second)
        #expect(first.rawValue.count == 26 && Lexical.isValidID(first.rawValue.utf8))
    }

    // MARK: Review-copy mode (review format §2.4, appendix A)

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

    static func parseCopy(_ text: String) -> ParsedReviewCopy {
        ReviewCopyFormat.parse(Data(text.utf8), opened: openedAt)
    }

    @Test func s2_1_aCopyIsRecognisedByItsExportID() {
        let parsed = Self.parseCopy(Self.tide)
        #expect(parsed.recognition == .reviewCopy(Self.export, exported: Self.exported))
        #expect(parsed.parsed.newEntries.isEmpty)
        #expect(parsed.parsed.book.scenes.map(\.title.text) == ["Dawn", "Dusk"])
    }

    @Test func s2_3_withoutExportItIsNotACopy() {
        let parsed = Self.parseCopy(
            Self.tide.replacingOccurrences(of: "export: 01JDB2C7Q9X4M8T6V3N5R1K0PZ\n", with: ""))
        #expect(parsed.recognition == .notAReviewCopy)
        #expect(parsed.parsed.newEntries.isEmpty, "exported alone is a known key, so no entry")
    }

    @Test func s2_4_aSceneWithNoIDGetsItsPosition() {
        let parsed = Self.parseCopy(Self.tide.replacingOccurrences(of: "id: s2\n", with: ""))
        #expect(parsed.parsed.book.scenes.map(\.id.rawValue) == ["s1", "scene-2"])
        #expect(
            parsed.parsed.newEntries == [
                ErrorEntry(.notice, "This scene had no id, so it was given scene-2.")
            ])
    }

    @Test func s2_4_aPositionalIDInUseGetsASuffix() {
        let text = Self.tide.replacingOccurrences(of: "id: s2\n", with: "").replacingOccurrences(
            of: "id: s1", with: "id: scene-2")
        let parsed = Self.parseCopy(text)
        #expect(parsed.parsed.book.scenes.map(\.id.rawValue) == ["scene-2", "scene-2-2"])
        #expect(
            parsed.parsed.newEntries == [
                ErrorEntry(.notice, "This scene had no id, so it was given scene-2-2.")
            ]
        )
    }

    @Test func s2_4_aDuplicateIDGetsItsPosition() {
        let parsed = Self.parseCopy(Self.tide.replacingOccurrences(of: "id: s2", with: "id: s1"))
        #expect(parsed.parsed.book.scenes.map(\.id.rawValue) == ["s1", "scene-2"])
        #expect(
            parsed.parsed.newEntries == [
                ErrorEntry(
                    .notice,
                    "This scene's id s1 was already used by an earlier scene, so it was given scene-2.")
            ])
    }

    @Test func s2_4_aBadIDIsAnEntryAndTheSceneGetsItsPosition() {
        let parsed = Self.parseCopy(Self.tide.replacingOccurrences(of: "id: s2", with: "id: not valid!"))
        #expect(parsed.parsed.book.scenes.map(\.id.rawValue) == ["s1", "scene-2"])
        #expect(
            parsed.parsed.newEntries == [
                ErrorEntry(.metadata, "id: not valid!"),
                ErrorEntry(.notice, "This scene had no id, so it was given scene-2."),
            ])
    }

    @Test func positionalIDsAreTheSameAtEveryOpen() {
        let text = Self.tide.replacingOccurrences(of: "id: s2\n", with: "").replacingOccurrences(
            of: "id: s1\n", with: "")
        let first = Self.parseCopy(text).parsed.book.scenes.map(\.id)
        let second = ReviewCopyFormat.parse(Data(text.utf8), opened: Self.exported).parsed.book.scenes.map(
            \.id)
        #expect(first == second)
        #expect(first.map(\.rawValue) == ["scene-1", "scene-2"])
    }

    @Test func s2_4_aCopyMangledInTheMailReadsTheSame() {
        let mangled = Self.tide.replacingOccurrences(
            of: "The ferry left at dawn.", with: "The ferry left\nat dawn."
        )
        .replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = Self.parseCopy(mangled)
        #expect(parsed.parsed.book == Self.parseCopy(Self.tide).parsed.book)
        #expect(parsed.recognition == .reviewCopy(Self.export, exported: Self.exported))
        #expect(parsed.parsed.newEntries.isEmpty)
    }

    @Test func aBadExportIDIsAnEntryAndNotACopy() {
        let parsed = Self.parseCopy(
            Self.tide.replacingOccurrences(of: "01JDB2C7Q9X4M8T6V3N5R1K0PZ", with: "not valid!"))
        #expect(parsed.recognition == .notAReviewCopy)
        #expect(parsed.parsed.newEntries == [ErrorEntry(.frontMatter, "export: not valid!")])
    }

    @Test func aBadExportedDateIsAnEntryButStillACopy() {
        let parsed = Self.parseCopy(
            Self.tide.replacingOccurrences(of: "2026-11-03T10:15:00-08:00", with: "Tuesday"))
        #expect(parsed.recognition == .reviewCopy(Self.export, exported: nil))
        #expect(parsed.parsed.newEntries == [ErrorEntry(.frontMatter, "exported: Tuesday")])
    }

    @Test func aMissingExportedDateIsSilent() {
        let parsed = Self.parseCopy(
            Self.tide.replacingOccurrences(of: "exported: 2026-11-03T10:15:00-08:00\n", with: ""))
        #expect(parsed.recognition == .reviewCopy(Self.export, exported: nil))
        #expect(parsed.parsed.newEntries.isEmpty)
    }

    @Test func inABookTheCopysKeysAreUnknown() {
        let parsed = parse(Self.tide)
        #expect(
            parsed.newEntries == [
                ErrorEntry(.frontMatter, "export: 01JDB2C7Q9X4M8T6V3N5R1K0PZ"),
                ErrorEntry(.frontMatter, "exported: 2026-11-03T10:15:00-08:00"),
            ])
    }
}
