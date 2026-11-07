import Testing

@testable import SceneItCore

/// Made with an expression: in a type position, `Comment` is ambiguous with the testing library's.
private let comment = { @Sendable (id: String, color: PaletteColor, text: String) in
    Comment(
        id: CommentID(rawValue: id), color: color, text: text,
        created: Timestamp(secondsSince1970: 1_700_000_000, offset: .zero))
}

private func ids(_ raw: String...) -> Set<CommentID> {
    Set(raw.map(CommentID.init(rawValue:)))
}

/// The comments panel's search (PLAN §8.1): plain words must all appear in the text; `#color`
/// tokens filter by color, any of them, `#grey` and `#gray` alike, and combine with words.
struct CommentQueryTests {
    @Test func plainWordsAreLowercasedAndAllMustAppear() {
        let query = CommentQuery("  Ferry   SCHEDULE ")
        #expect(query.words == ["ferry", "schedule"])
        #expect(query.colors.isEmpty && query.unknownColors.isEmpty)
        #expect(query.matches(comment("a", .red, "Check the ferry schedule for the 1950s.")))
        #expect(!query.matches(comment("b", .red, "Check the ferry.")), "every word must appear")
        #expect(query.matches(comment("c", .red, "The FerrySchedule")), "words match within words")
    }

    @Test func colorTokensFilterByAnyOfTheirColors() {
        let query = CommentQuery("#red #Blue")
        #expect(query.colors == [.red, .blue])
        #expect(query.words.isEmpty)
        #expect(query.matches(comment("a", .red, "x")))
        #expect(query.matches(comment("b", .blue, "x")))
        #expect(!query.matches(comment("c", .purple, "x")))
    }

    @Test func greyAndGrayAreBothGray() {
        #expect(CommentQuery("#grey").colors == [.gray])
        #expect(CommentQuery("#gray").colors == [.gray])
        #expect(CommentQuery("#grey #gray").colors == [.gray], "the chip shows once")
    }

    @Test func colorsCombineWithWords() {
        let query = CommentQuery("#red ferry")
        #expect(query.colors == [.red] && query.words == ["ferry"])
        #expect(query.matches(comment("a", .red, "Check the ferry schedule.")))
        #expect(!query.matches(comment("b", .red, "Swore at it?")))
        #expect(!query.matches(comment("c", .blue, "The ferry again.")))
    }

    /// One rule with `book.md`'s (`PaletteColor(named:)`): any ASCII case, and nothing else.
    @Test func colorNamesAreCaseInsensitiveInASCIIOnly() {
        #expect(CommentQuery("#RED #Grey").colors == [.red, .gray])
        #expect(CommentQuery("#blac\u{212A}").unknownColors == ["#blac\u{212A}".lowercased()])
        #expect(PaletteColor(named: "PINK") == .pink)
    }

    @Test func everyPaletteColorIsRecognizedBlackIncluded() {
        for color in PaletteColor.allCases {
            #expect(CommentQuery("#\(color.rawValue)").colors == [color])
        }
    }

    /// An unknown name is flagged and filters nothing; a lone `#` is nothing at all.
    @Test func anUnknownColorIsFlaggedAndFiltersNothing() {
        let query = CommentQuery("#mauve #Mauve letter # #red")
        #expect(query.unknownColors == ["#mauve"])
        #expect(query.colors == [.red])
        #expect(query.words == ["letter"])
        let onlyUnknown = CommentQuery("#mauve")
        #expect(onlyUnknown.isEmpty, "nothing to filter by")
        #expect(onlyUnknown.matches(comment("a", .pink, "Anything")))
    }

    @Test func anEmptyQueryMatchesEverything() {
        #expect(CommentQuery("   ").isEmpty)
        #expect(CommentQuery("").matches(comment("a", .black, "")))
    }
}

/// The panel's cards (PLAN §8.1): anchored comments in the order their text starts on the page,
/// with a quote of it; detached ones (detach detection) after them, in the scene's order.
struct CommentCardsTests {
    private static let scene = BookScene(
        id: SceneID(rawValue: "s"), modified: Timestamp(secondsSince1970: 1_700_000_000, offset: .zero),
        title: "One",
        body: [
            [
                Run("The ferry left", comments: ids("late")), Run(" at dawn, "),
                Run("Mara", comments: ids("early")),
            ],
            [
                Run("She ", comments: ids("both")), Run("packed", comments: ids("both", "tie")),
                Run(" in the dark."),
            ],
        ],
        comments: [
            comment("early", .purple, "Who?"), comment("gone", .gray, "Cut"), comment("late", .red, "When?"),
            comment("tie", .blue, "Why?"), comment("both", .green, "Hm"), comment("lost", .pink, "Was here"),
        ])

    @Test func anchoredCardsAreInTextOrderAndTiesKeepTheScenesOrder() {
        let cards = CommentCards(Self.scene)
        for card in cards.anchored { #expect(!Self.scene.isDetached(card.id), "precondition: anchored") }
        #expect(cards.anchored.map(\.id.rawValue) == ["late", "early", "both", "tie"])
        // "both" starts before "tie" (at "She "); were they to start together, the list order decides.
        let together = BookScene(
            id: SceneID(rawValue: "t"), modified: Self.scene.modified, title: "Two",
            body: [[Run("Dawn", comments: ids("b", "a"))]],
            comments: [comment("b", .red, ""), comment("a", .red, "")])
        #expect(CommentCards(together).anchored.map(\.id.rawValue) == ["b", "a"])
    }

    @Test func detachedCommentsComeAfterInTheScenesOrder() {
        let cards = CommentCards(Self.scene)
        #expect(cards.detached.map(\.id.rawValue) == ["gone", "lost"])
        #expect(cards.detached.allSatisfy { $0.quote.isEmpty })
        #expect(cards.all.map(\.id.rawValue) == ["late", "early", "both", "tie", "gone", "lost"])
        for card in cards.detached { #expect(Self.scene.isDetached(card.id), "precondition: detached") }
    }

    @Test func aQuoteJoinsItsRunsAndLineBreaksAndMarksAGap() {
        let cards = CommentCards(Self.scene)
        func quote(_ id: String) -> String? { cards.all.first { $0.id.rawValue == id }?.quote }
        #expect(quote("late") == "The ferry left")
        #expect(quote("both") == "She packed", "two runs, one stretch")
        let pieces = BookScene(
            id: SceneID(rawValue: "p"), modified: Self.scene.modified, title: "Three",
            body: [
                [Run("End", comments: ids("x")), Run(" of it.")], [Run("Again", comments: ids("x"))],
                [Run("Last", comments: ids("y"))], [Run("line", comments: ids("y"))],
            ],
            comments: [comment("x", .red, ""), comment("y", .red, "")])
        let split = CommentCards(pieces)
        #expect(split.anchored.first?.quote == "End" + CommentWording.quoteGap + "Again")
        #expect(split.anchored.last?.quote == "Last line", "only a line break between: one stretch")
    }

    /// As `book.md` writes it (one range, §4.2): only paragraph breaks between, an empty
    /// paragraph included, is one stretch.
    @Test func aStretchGoesOnAcrossAnEmptyParagraph() throws {
        let scene = BookScene(
            id: SceneID(rawValue: "e"), modified: Self.scene.modified, title: "Four",
            body: [[Run("A", comments: ids("z"))], [], [Run("B", comments: ids("z"))]],
            comments: [comment("z", .red, "")])
        #expect(CommentCards(scene).anchored.map(\.quote) == ["A  B"])
        let written = String(
            decoding: try BookFormat.verifiedSerialization(of: Book(title: "T", scenes: [scene])),
            as: UTF8.self)
        #expect(written.contains("| c0-4 |"), "book.md agrees: one range")
    }

    @Test func filteringKeepsTheOrderAndTheGroups() {
        let cards = CommentCards(Self.scene).filtered(by: CommentQuery("#red #pink #gray"))
        #expect(cards.anchored.map(\.id.rawValue) == ["late"])
        #expect(cards.detached.map(\.id.rawValue) == ["gone", "lost"])
        #expect(CommentCards(Self.scene).filtered(by: CommentQuery("#black")).isEmpty)
        #expect(CommentCards(Self.scene).filtered(by: CommentQuery("")) == CommentCards(Self.scene))
    }
}

@MainActor
struct CommentSelectionOpeningTests {
    let scene = SceneID(rawValue: "scene")
    let first = CommentID(rawValue: "c1")
    let second = CommentID(rawValue: "c2")

    @Test func anOpenedCommentIsSelectedAndItsCardAskedOnceToTakeTheFocus() {
        let selection = CommentSelection()
        selection.open(first, in: scene)
        #expect(selection.comment(in: scene) == first)
        #expect(!selection.takeOpening(second, in: scene))
        #expect(!selection.takeOpening(first, in: SceneID(rawValue: "other")))
        #expect(selection.takeOpening(first, in: scene))
        #expect(!selection.takeOpening(first, in: scene), "answered once")
        #expect(selection.comment(in: scene) == first)
    }

    @Test func selectingAnotherCommentOrNoneCancelsTheOpening() {
        let selection = CommentSelection()
        selection.open(first, in: scene)
        selection.select(second, in: scene)
        #expect(!selection.takeOpening(first, in: scene))
        selection.open(first, in: scene)
        selection.deselect()
        #expect(!selection.takeOpening(first, in: scene))
    }
}
