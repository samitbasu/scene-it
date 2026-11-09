import AppKit
import Testing

@testable import SceneItCore

/// The printed text (PLAN §10.1): each scene's title as an 18 pt bold heading over its body, the
/// typography smartened; laid out by TextKit 2 on Letter paper, portrait for text only and
/// landscape with a comment column, with no comment overlapping another.
@MainActor
struct ManuscriptPagesTests {
    static let modified = Timestamp("2026-11-03T10:15:00-08:00")!
    static let letter = CGSize(width: 612, height: 792)
    static let landscape = CGSize(width: 792, height: 612)

    static func comment(_ number: Int, _ color: PaletteColor = .purple, _ text: String = "Too early?")
        -> SceneItCore::Comment
    {
        SceneItCore::Comment(
            id: CommentID(rawValue: "01JC4K00000000000000000\(String(format: "%03d", number))"), color: color,
            text: text, created: Timestamp("2026-11-03T10:\(String(format: "%02d", number % 60)):00-08:00")!)
    }

    static func scene(
        _ title: String, _ body: [Paragraph], comments: [SceneItCore::Comment] = [], id: String = "ferry"
    ) -> BookScene {
        BookScene(
            id: SceneID(rawValue: id), modified: modified, title: SceneTitle(title), body: body,
            comments: comments)
    }

    static let sentence =
        "The ferry left at dawn, and Mara watched the harbor lights go out one by one behind her as the engines turned."

    static func long(_ paragraphs: Int) -> [Paragraph] {
        Array(repeating: [Run(sentence)], count: paragraphs)
    }

    @Test func theTitleIsAHeadingAndTheTypographyIsSmartened() throws {
        let manuscript = PrintManuscript([
            Self.scene(
                "The ferry's \"end\"", [[Run("\"Go,\" she said -- "), Run("quietly...", styles: [.italic])]])
        ])
        let text = manuscript.text
        #expect(
            text.string
                == "The ferry\u{2019}s \u{201C}end\u{201D}\n\u{201C}Go,\u{201D} she said \u{2014} quietly\u{2026}"
        )
        let title = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(title.pointSize == 18 && title.fontDescriptor.symbolicTraits.contains(.bold))
        let italic = (text.string as NSString).range(of: "quietly")
        let font = try #require(text.attribute(.font, at: italic.location, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 12 && font.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(manuscript.sceneStarts.isEmpty)
    }

    @Test func eachSceneAfterTheFirstStartsWhereItsTitleDoes() throws {
        let manuscript = PrintManuscript([
            Self.scene("One", [[Run("First.")], []], id: "a"), Self.scene("", [[Run("Second.")]], id: "b"),
            Self.scene("Three", [], id: "c"),
        ])
        let string = manuscript.text.string as NSString
        #expect(manuscript.text.string == "One\nFirst.\n\nSecond.\nThree")
        #expect(
            manuscript.sceneStarts == [
                string.range(of: "Second").location, string.range(of: "Three").location,
            ])
    }

    @Test func commentsAreInTheOrderTheyStartAndDetachedOnesAreLeftOut() throws {
        let (early, late, detached, sameStart) = (
            Self.comment(1), Self.comment(2), Self.comment(3), Self.comment(4)
        )
        let manuscript = PrintManuscript([
            Self.scene(
                "T",
                [
                    [Run("one "), Run("two", comments: [late.id]), Run(" three")],
                    [
                        Run("four", comments: [early.id, sameStart.id]),
                        Run(" five", comments: [sameStart.id]),
                    ],
                ], comments: [sameStart, late, early, detached])
        ])
        let string = manuscript.text.string as NSString
        #expect(
            manuscript.comments.map(\.firstStretch) == [
                string.range(of: "two"), string.range(of: "four"), string.range(of: "four five"),
            ])
        #expect(manuscript.hasComments)
    }

    @Test func textOnlyIsPortraitInManuscriptFormat() throws {
        let pages = ManuscriptPages(
            PrintManuscript([Self.scene("The ferry", Self.long(30))]), layout: .textOnly, paper: Self.letter)
        #expect(pages.geometry.text == CGRect(x: 72, y: 72, width: 468, height: 648))
        #expect(pages.geometry.comments == nil)
        try #require(pages.pageCount > 2, "precondition: several pages")
        for page in pages.pages.dropLast() {
            #expect(
                (22...24).contains(page.lines.count),
                "about 23 double-spaced lines a page: \(page.lines.count)")
        }
        #expect(pages.pages.allSatisfy { $0.comments.isEmpty })
    }

    @Test func textOnlyLeavesTheCommentsOut() {
        let comment = Self.comment(1)
        let pages = ManuscriptPages(
            PrintManuscript([Self.scene("T", [[Run("Hello", comments: [comment.id])]], comments: [comment])]),
            layout: .textOnly, paper: Self.letter)
        #expect(pages.pages.flatMap(\.comments).isEmpty)
    }

    @Test func aSceneStartsANewPage() throws {
        let pages = ManuscriptPages(
            PrintManuscript([
                Self.scene("One", [[Run("Short.")]], id: "a"),
                Self.scene("Two", [[Run("Also short.")]], id: "b"),
            ]),
            layout: .textOnly, paper: Self.letter)
        #expect(pages.pageCount == 2)
    }

    @Test func withCommentsIsLandscapeWithAColumnOnTheRight() throws {
        let geometry = PrintGeometry(paper: Self.landscape, layout: .withComments)
        let column = try #require(geometry.comments)
        #expect(geometry.text == CGRect(x: 72, y: 72, width: 468, height: 468), "the page's 6.5 in column")
        #expect(column == CGRect(x: 558, y: 72, width: 198, height: 468))
        #expect(column.minX > Self.landscape.width * 2 / 3, "in the right third")
    }

    @Test func narrowPaperNarrowsTheTextColumn() {
        let a4 = PrintGeometry(paper: CGSize(width: 595, height: 842), layout: .textOnly)
        #expect(a4.text == CGRect(x: 72, y: 72, width: 451, height: 698))
    }

    /// Many comments, crowded on a few lines, over several pages: each is level with its line or
    /// pushed below the one above, none overlaps another, and none runs off its page.
    @Test func commentBoxesNeverOverlap() throws {
        let comments = (0..<24).map {
            Self.comment(
                $0, PaletteColor.allCases[$0 % 7], String(repeating: "A longer remark. ", count: $0 % 4 + 1))
        }
        var body: [Paragraph] = []
        for (index, comment) in comments.enumerated() {
            body.append([Run("Line \(index) "), Run("marked", comments: [comment.id]), Run(" here.")])
            if index % 3 == 0 { body.append([Run("Plain words "), Run("again", comments: [comment.id])]) }
        }
        let pages = ManuscriptPages(
            PrintManuscript([Self.scene("Crowded", body, comments: comments)]), layout: .withComments,
            paper: Self.landscape)
        let column = try #require(pages.geometry.comments)
        try #require(pages.pageCount > 1, "precondition: several pages")
        try #require(
            pages.pages.contains { page in
                page.comments.contains { $0.top > PaperLength(0) && $0.anchor == .onPage }
            },
            "precondition: some comments")
        var pushed = 0
        for index in 0..<pages.pageCount {
            let boxes = pages.commentBoxes(onPage: index)
            for (above, below) in zip(boxes, boxes.dropFirst()) {
                #expect(below.minY >= above.maxY, "page \(index + 1): \(above) and \(below) overlap")
            }
            for box in boxes {
                #expect(box.minY >= column.minY && box.maxY <= column.maxY, "inside the column")
            }
            pushed +=
                zip(pages.pages[index].comments, pages.levels(onPage: index)).filter { $0.top > $1 }.count
        }
        #expect(pages.pages.flatMap(\.comments).count == comments.count, "every comment printed")
        #expect(pushed > 0, "some were pushed down")
    }

    @Test func aCommentIsLevelWithTheTopOfItsLine() throws {
        let comment = Self.comment(1)
        let pages = ManuscriptPages(
            PrintManuscript([
                Self.scene(
                    "Ferry", [[Run(Self.sentence)], [Run("Then "), Run("dawn", comments: [comment.id])]],
                    comments: [comment])
            ]), layout: .withComments, paper: Self.landscape)
        let placed = try #require(pages.pages.first?.comments.first)
        let level = try #require(pages.levels(onPage: 0).first)
        #expect(placed.top == level)
        #expect(placed.top > PaperLength(60), "below the title and the first paragraph's lines")
    }

    /// Several comments leave one line, two of them overlapping: each connector has a lane of its
    /// own, below every underline on the line and above the next line's letters, and the further
    /// left one leaves the text, the lower its lane, so none crosses another.
    @Test func eachConnectorOnALineHasItsOwnLane() throws {
        let (a, b, c, d) = (
            Self.comment(1, .purple), Self.comment(2, .red), Self.comment(3, .blue), Self.comment(4, .green)
        )
        let pages = ManuscriptPages(
            PrintManuscript([
                Self.scene(
                    "Ferry",
                    [
                        [
                            Run("He found the "), Run("letter", comments: [a.id]), Run(" under the "),
                            Run("bench", comments: [b.id, c.id]), Run(" an hour", comments: [c.id]),
                            Run(" later, but she was "), Run("already ashore", comments: [d.id]), Run("."),
                        ],
                        [Run(Self.sentence)],
                    ], comments: [a, b, c, d])
            ]), layout: .withComments, paper: Self.landscape)
        let connectors = (0..<pages.commentCount).map { pages.connector(ofNote: $0) }
        try #require(
            connectors.count == 4 && Set(connectors.map(\.line)).count == 1, "precondition: four on one line")
        #expect(Set(connectors.map(\.lane)).count == 4, "four lanes")
        for (left, right) in zip(connectors.dropFirst(), connectors) {
            #expect(left.leaves < right.leaves, "the column takes them right to left")
            #expect(left.lane > right.lane, "the further left, the lower")
        }
        for connector in connectors {
            #expect(connector.lane > connector.band.top, "below the line's deepest underline")
            #expect(connector.lane < connector.band.bottom, "above what the next line keeps clear")
            let next = try #require(connector.nextLineTop)
            #expect(connector.band.bottom <= next, "the band ends above the next line's letters")
        }
        let line = connectors[0].line
        #expect(
            connectors[0].band.top == pages.baseline(ofLine: line) + PaperLength(UnderlineStyle.top(of: 2)),
            "below both of the stacked underlines under \"bench\"")
    }

    @Test func onlyRangesWithSomethingToPrintAreOffered() {
        let story = Self.scene("Story", [[Run("Words.")]], id: "story")
        let cut = Self.scene("Cut", [[Run("Gone.")]], id: "cut")
        let onlyBoneyard = Book(title: "B", scenes: [], boneyard: [cut])
        #expect(
            PrintRange.offered(in: onlyBoneyard, open: cut.id) == [.thisScene], "no whole manuscript to print"
        )
        #expect(PrintRange.offered(in: onlyBoneyard, open: nil).isEmpty)
        let book = Book(title: "B", scenes: [story], boneyard: [cut])
        #expect(PrintRange.offered(in: book, open: nil) == [.wholeManuscript])
        #expect(PrintRange.offered(in: book, open: cut.id) == PrintRange.allCases)
        #expect(PrintRange.wholeManuscript.scenes(of: book, open: cut.id).map(\.id) == [story.id])
    }

    /// The preview lays the whole manuscript out again whenever the dialog asks; a long book
    /// (about 300 pages) must not lay out pathologically slowly. The time is printed for the
    /// record; the limit is generous, so a loaded machine doesn't fail it (#167, #178).
    @Test func aLongManuscriptLaysOutQuickly() throws {
        let scenes = (0..<30).map { Self.scene("Scene \($0)", Self.long(110), id: "s\($0)") }
        let clock = ContinuousClock()
        var pages: ManuscriptPages?
        let elapsed = clock.measure {
            pages = ManuscriptPages(PrintManuscript(scenes), layout: .textOnly, paper: Self.letter)
        }
        let count = try #require(pages?.pageCount)
        try #require(count >= 250, "precondition: a long book, \(count) pages")
        print("Print layout: \(count) pages in \(elapsed)")
        #expect(elapsed < .seconds(30), "\(count) pages in \(elapsed)")
    }
}

extension ManuscriptPages {
    /// Where each comment on page `index` would sit if nothing pushed it: level with its line.
    func levels(onPage index: Int) -> [PaperLength] {
        let page = pages[index]
        let pageTop = page.lines.first.map { lineTop($0) } ?? 0
        return page.comments.map { PaperLength(lineTop(noteLine($0.comment)) - pageTop) }
    }
}
