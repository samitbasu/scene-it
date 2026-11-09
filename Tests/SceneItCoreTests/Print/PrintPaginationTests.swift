import CoreGraphics
import Testing

@testable import SceneItCore

/// Where printed pages break and where the margin column's comments go (PLAN §10.1): level with
/// their lines, pushed down past each other, never split across pages.
struct PrintPaginationTests {
    static let height = PaperLength(100)
    static let spacing = PaperLength(4)

    /// `count` lines 10 pt apart, each 6 pt of letters.
    static func lines(_ count: Int, newPageAt starts: Set<Int> = []) -> [PrintLine] {
        (0..<count).map { index in
            PrintLine(
                top: PaperLength(CGFloat(index) * 10), bottom: PaperLength(CGFloat(index) * 10 + 6),
                start: starts.contains(index) ? .newPage : .continuing)
        }
    }

    static func comment(_ line: Int, _ height: CGFloat) -> MarginComment {
        MarginComment(line: line, height: PaperLength(height))
    }

    static func pages(_ lines: [PrintLine], _ comments: [MarginComment] = []) -> [PrintPage] {
        let pages = PrintPagination.pages(lines: lines, comments: comments, height: height, spacing: spacing)
        expectWellFormed(pages, lines: lines, comments: comments)
        return pages
    }

    /// Where a line's top is on the page that holds it.
    static func levelOnPage(_ line: Int, _ page: PrintPage, _ lines: [PrintLine]) -> PaperLength {
        lines[line].top - lines[page.lines.lowerBound].top
    }

    /// What holds for every pagination: the pages take the lines in order, each once, and every
    /// line fits its page; every comment is placed once, in order, inside its column, apart from
    /// the one above by the spacing, and never above its own line; one anchored on its page is
    /// on the page that holds its line.
    static func expectWellFormed(_ pages: [PrintPage], lines: [PrintLine], comments: [MarginComment]) {
        #expect(pages.flatMap { Array($0.lines) } == Array(lines.indices), "every line once, in order")
        let order = comments.indices.sorted { (comments[$0].line, $0) < (comments[$1].line, $1) }
        #expect(pages.flatMap { $0.comments.map(\.comment) } == order, "every comment once, in order")
        for page in pages {
            if let first = page.lines.first {
                for line in page.lines {
                    #expect(
                        lines[line].bottom - lines[first].top <= height || line == first, "line \(line) fits")
                }
            }
            for (above, below) in zip(page.comments, page.comments.dropFirst()) {
                #expect(
                    below.top >= above.bottom + spacing, "comment \(below.comment) clears \(above.comment)")
            }
            for placed in page.comments {
                #expect(placed.bottom <= height, "comment \(placed.comment) inside the column")
                let line = comments[placed.comment].line
                switch placed.anchor {
                case .onPage:
                    #expect(page.lines.contains(line), "comment \(placed.comment) is on its line's page")
                    #expect(placed.top >= levelOnPage(line, page, lines), "never above its line")
                case .carriedOver:
                    #expect(page.lines.first.map { line < $0 } ?? true, "its line was on an earlier page")
                    if let first = page.lines.first {
                        #expect(
                            !lines[(line + 1)...first].contains { $0.start == .newPage },
                            "comment \(placed.comment) stays with its own scene")
                    }
                }
            }
        }
    }

    @Test func linesFillAPageAndBreakBeforeTheFirstThatDoesntFit() throws {
        let lines = Self.lines(25)
        try #require(lines[24].bottom > Self.height, "precondition: more than a page")
        let pages = Self.pages(lines)
        #expect(pages.map(\.lines) == [0..<10, 10..<20, 20..<25])
        #expect(pages.allSatisfy { $0.comments.isEmpty })
    }

    @Test func aLineWhoseLettersFitIsKeptThoughItsSpacingWouldNot() throws {
        let lines = [
            PrintLine(top: .zero, bottom: PaperLength(6)),
            PrintLine(top: PaperLength(90), bottom: PaperLength(100)),
        ]
        #expect(Self.pages(lines).map(\.lines) == [0..<2])
    }

    @Test func aNewSceneStartsANewPage() {
        let pages = Self.pages(Self.lines(6, newPageAt: [4]))
        #expect(pages.map(\.lines) == [0..<4, 4..<6])
    }

    @Test func aCommentIsLevelWithItsLine() throws {
        let lines = Self.lines(25)
        let pages = Self.pages(lines, [Self.comment(3, 12), Self.comment(14, 12)])
        let first = try #require(pages[0].comments.first)
        #expect(first.top == PaperLength(30) && first.anchor == .onPage)
        let second = try #require(pages[1].comments.first)
        #expect(second.top == PaperLength(40), "level with line 14, the fifth on its page")
    }

    @Test func overlappingCommentsArePushedDown() throws {
        let comments = [Self.comment(1, 25), Self.comment(2, 10), Self.comment(2, 10)]
        try #require(PaperLength(10) + comments[0].height > PaperLength(20), "precondition: they'd overlap")
        let page = try #require(Self.pages(Self.lines(8), comments).first)
        #expect(page.comments.map(\.top) == [PaperLength(10), PaperLength(39), PaperLength(53)])
        #expect(page.comments.allSatisfy { $0.anchor == .onPage })
    }

    @Test func aCommentPushedPastThePageEndTakesItsLineToTheNextPage() throws {
        let lines = Self.lines(14)
        let comments = [Self.comment(5, 40), Self.comment(8, 30)]
        try #require(lines[8].bottom <= Self.height, "precondition: line 8 fits the first page")
        try #require(
            PaperLength(50) + comments[0].height + Self.spacing + comments[1].height > Self.height,
            "precondition: pushed below the first, the second runs past the end")
        let pages = Self.pages(lines, comments)
        #expect(pages.map(\.lines) == [0..<8, 8..<14])
        #expect(pages[1].comments.first?.top == .zero, "level with its line at the top of the page")
        #expect(pages[1].comments.first?.anchor == .onPage)
    }

    @Test func aCommentOnAPagesLastLineThatDoesntFitBelowItMovesTheLine() throws {
        let lines = Self.lines(12)
        let comments = [Self.comment(9, 20)]
        try #require(lines[9].bottom <= Self.height, "precondition: line 9 is the first page's last")
        try #require(lines[10].bottom > Self.height, "precondition")
        let pages = Self.pages(lines, comments)
        #expect(pages.map(\.lines) == [0..<9, 9..<12])
        #expect(pages[1].comments.map(\.top) == [.zero])
    }

    @Test func aCommentOnTheTextsLastLineFitsBesideIt() throws {
        let lines = Self.lines(5)
        let pages = Self.pages(lines, [Self.comment(4, 20)])
        #expect(pages.map(\.lines) == [0..<5])
        #expect(pages[0].comments.map(\.top) == [PaperLength(40)])
    }

    @Test func aCommentOnTheTextsLastLineThatDoesntFitMovesIt() throws {
        let lines = Self.lines(10)
        try #require(lines[9].bottom <= Self.height, "precondition: the text fits one page")
        let pages = Self.pages(lines, [Self.comment(9, 30)])
        #expect(pages.map(\.lines) == [0..<9, 9..<10])
        #expect(pages[1].comments.map(\.top) == [.zero])
    }

    @Test func manyCommentsOnOneLineStackAndTheRestCarryOverInOrder() throws {
        let comments = (0..<6).map { _ in Self.comment(0, 30) }
        try #require(
            comments.reduce(PaperLength.zero) { $0 + $1.height + Self.spacing } > Self.height,
            "precondition: more than a column holds")
        let pages = Self.pages(Self.lines(15), comments)
        #expect(pages.map(\.lines) == [0..<10, 10..<15])
        #expect(pages[0].comments.map(\.comment) == [0, 1, 2])
        #expect(pages[0].comments.map(\.top) == [.zero, PaperLength(34), PaperLength(68)])
        #expect(pages[1].comments.map(\.comment) == [3, 4, 5])
        #expect(pages[1].comments.allSatisfy { $0.anchor == .carriedOver })
    }

    @Test func carriedCommentsComeBeforeTheNextPagesOwn() throws {
        let comments = (0..<4).map { _ in Self.comment(0, 30) } + [Self.comment(11, 10)]
        let pages = Self.pages(Self.lines(15), comments)
        #expect(pages[1].comments.map(\.comment) == [3, 4])
        #expect(pages[1].comments.map(\.anchor) == [.carriedOver, .onPage])
        #expect(pages[1].comments[1].top == PaperLength(34), "pushed below the carried one")
    }

    @Test func aLineAfterACarriedCommentWaitsForTheNextPage() throws {
        let comments = (0..<4).map { _ in Self.comment(0, 30) } + [Self.comment(5, 5)]
        try #require(
            PaperLength(50) + comments[4].height <= Self.height,
            "precondition: the last would fit beside its line")
        let pages = Self.pages(Self.lines(8), comments)
        #expect(pages.map(\.lines) == [0..<5, 5..<8], "so the comments keep their order")
    }

    /// A scene's comments still waiting at its end get a page of their own, not the next
    /// scene's first page, beside the wrong text.
    @Test func aScenesLeftoverCommentsGetTheirOwnPageBeforeTheNextScene() throws {
        let lines = Self.lines(6, newPageAt: [3])
        let comments = (0..<4).map { _ in Self.comment(2, 30) } + [Self.comment(3, 10)]
        try #require(
            comments[..<4].reduce(PaperLength.zero) { $0 + $1.height + Self.spacing } > Self.height,
            "precondition: the first scene's last line has more than a column holds")
        let pages = Self.pages(lines, comments)
        #expect(pages.map(\.lines) == [0..<2, 2..<3, 3..<3, 3..<6], "the crowded line starts a page")
        #expect(pages[1].comments.map(\.comment) == [0, 1, 2])
        #expect(pages[2].comments.map(\.comment) == [3], "the one left over has a page of its own")
        #expect(pages[2].comments.allSatisfy { $0.anchor == .carriedOver })
        #expect(pages[3].comments.map(\.comment) == [4])
        #expect(pages[3].comments.first?.top == .zero, "level with the new scene's first line")
    }

    @Test func carriedCommentsPastTheLastLineGetPagesOfTheirOwn() throws {
        let comments = (0..<8).map { _ in Self.comment(0, 30) }
        let pages = Self.pages(Self.lines(2), comments)
        #expect(pages.map(\.lines) == [0..<2, 2..<2, 2..<2])
        #expect(pages.map(\.comments.count) == [3, 3, 2])
    }

    @Test func aCommentTallerThanAColumnIsAsTallAsTheColumn() throws {
        let pages = Self.pages(Self.lines(3), [Self.comment(0, 500)])
        #expect(pages[0].comments.first?.height == Self.height)
    }

    @Test func noTextIsNoPages() {
        #expect(Self.pages([]).isEmpty)
    }

    @Test func commentsOnLinesThatDontExistAreLeftOut() {
        let pages = PrintPagination.pages(
            lines: Self.lines(2), comments: [Self.comment(5, 10)], height: Self.height, spacing: Self.spacing)
        #expect(pages.flatMap(\.comments).isEmpty)
    }

    @Test func paperLengthsAreNeverNegative() {
        #expect(PaperLength(-3) == .zero)
        #expect(PaperLength(.nan) == .zero)
        #expect(PaperLength(2) - PaperLength(5) == .zero)
        #expect(CGFloat(PaperLength(2) + PaperLength(5)) == 7)
    }

    /// Random texts and comments, seeded so a failure repeats: every pagination is well formed.
    @Test(arguments: 0..<40)
    func randomPaginationsAreWellFormed(seed: UInt64) {
        var random = SeededRandom(seed: seed)
        var lines: [PrintLine] = []
        var top: CGFloat = 0
        for index in 0..<Int.random(in: 0...60, using: &random) {
            let height = CGFloat(Int.random(in: 4...20, using: &random))
            let start: PrintLine.LineStart =
                index > 0 && Int.random(in: 0..<15, using: &random) == 0 ? .newPage : .continuing
            lines.append(PrintLine(top: PaperLength(top), bottom: PaperLength(top + height), start: start))
            top += height + CGFloat(Int.random(in: 0...12, using: &random))
        }
        let comments = (0..<Int.random(in: 0...30, using: &random)).map { _ in
            Self.comment(
                Int.random(in: 0..<max(lines.count, 1), using: &random),
                CGFloat(Int.random(in: 5...60, using: &random)))
        }
        let pages = PrintPagination.pages(
            lines: lines, comments: lines.isEmpty ? [] : comments, height: Self.height, spacing: Self.spacing)
        Self.expectWellFormed(pages, lines: lines, comments: lines.isEmpty ? [] : comments)
    }
}

/// SplitMix64.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
