import Testing

@testable import SceneItCore

/// Export as SceneIt…'s scene chooser: everything ticked to begin with, clicks and Shift-click
/// ranges.
struct ExportChoiceTests {
    static let ids = (1...6).map { SceneID(rawValue: "s\($0)") }

    static func choice() -> ExportChoice {
        let story = ids.enumerated().map { index, id in
            BookScene(
                id: id, modified: Timestamp(secondsSince1970: 0, offset: .zero),
                title: SceneTitle(index == 2 ? "" : "Scene \(index + 1)"))
        }
        return ExportChoice(book: Book(title: "T", scenes: story))
    }

    static func ticked(_ choice: ExportChoice) -> [Int] {
        ids.indices.filter { choice.isTicked(ids[$0]) }.map { $0 + 1 }
    }

    @Test func everyStorySceneIsListedInOrderAndTicked() {
        let choice = Self.choice()
        #expect(choice.rows.map(\.id) == Self.ids)
        #expect(choice.rows.map(\.number) == [1, 2, 3, 4, 5, 6])
        #expect(choice.rows[2].name == WindowWording.untitledScene)
        #expect(ExportWording.row(choice.rows[0]) == "1. Scene 1")
        #expect(choice.allTicked && choice.canExport)
        #expect(ExportWording.tickedCount(choice.ticked.count, of: choice.rows.count) == "6 of 6 scenes")
    }

    @Test func aClickTogglesOneScene() {
        var choice = Self.choice()
        choice.click(Self.ids[1], .single)
        #expect(Self.ticked(choice) == [1, 3, 4, 5, 6])
        choice.click(Self.ids[1], .single)
        #expect(Self.ticked(choice) == [1, 2, 3, 4, 5, 6])
    }

    @Test func aShiftClickSetsTheRunFromTheLastClickAsTheClickedSceneBecomes() {
        var choice = Self.choice()
        choice.click(Self.ids[1], .single)
        choice.click(Self.ids[4], .extendingRange)
        #expect(Self.ticked(choice) == [1, 6], "scenes 2 to 5 unticked, as scene 5 became")
        choice.click(Self.ids[0], .extendingRange)
        #expect(Self.ticked(choice) == [6], "back up to scene 1, from scene 5: scene 1 was ticked, so all go")
        choice.click(Self.ids[2], .extendingRange)
        #expect(Self.ticked(choice) == [1, 2, 3, 6], "from scene 1 down to 3, ticking")
    }

    @Test func aShiftClickWithNothingClickedYetActsOnOneScene() {
        var choice = Self.choice()
        choice.click(Self.ids[3], .extendingRange)
        #expect(Self.ticked(choice) == [1, 2, 3, 5, 6])
    }

    @Test func selectNoneThenAllAndWhetherExportCanGoAhead() {
        var choice = Self.choice()
        choice.untickAll()
        #expect(choice.ticked.isEmpty && !choice.canExport && !choice.allTicked)
        choice.click(Self.ids[5], .single)
        #expect(choice.canExport && !choice.allTicked)
        #expect(ExportWording.tickedCount(1, of: 6) == "1 of 6 scenes")
        choice.tickAll()
        #expect(choice.allTicked)
    }

    @Test func anIDTheListDoesntHaveChangesNothing() {
        var choice = Self.choice()
        choice.click(SceneID(rawValue: "boneyard"), .single)
        #expect(choice.allTicked)
    }

    static func scene(_ index: Int, errors: [ErrorEntry] = []) -> BookScene {
        var scene = BookScene(
            id: ids[index], modified: Timestamp(secondsSince1970: 0, offset: .zero), title: SceneTitle("S"))
        scene.errors = errors
        return scene
    }

    /// Scenes 2 and 5 hold a line Scene It couldn't read, as a repaired book's `### Unparsed`
    /// sections do; scene 4 holds only repair notices.
    static func choiceWithUnreadableText(bookErrors: [ErrorEntry] = []) -> ExportChoice {
        let notices = [
            ErrorEntry(.notice, "The scene had no id."), ErrorEntry(.notice, "Characters changed."),
        ]
        let story = ids.indices.map { index in
            switch index {
            case 1, 4: scene(index, errors: [ErrorEntry(.line, "garbled \(index)")])
            case 3: scene(index, errors: notices)
            default: scene(index)
            }
        }
        var book = Book(title: "T", scenes: story)
        book.errors = bookErrors
        return ExportChoice(book: book)
    }

    @Test func theScenesLineShowsWhileATickedSceneHoldsUnreadableText() throws {
        var choice = Self.choiceWithUnreadableText()
        try #require(choice.allTicked, "precondition: all ticked")
        #expect(choice.leavesOutTickedScenesText, "all ticked")
        #expect(ExportWording.notes(for: choice) == [ExportWording.scenesTextLeftOut])

        choice.click(Self.ids[1], .single)
        #expect(choice.leavesOutTickedScenesText, "some ticked: scene 5 still is")
        choice.click(Self.ids[4], .single)
        #expect(
            Self.ticked(choice) == [1, 3, 4, 6], "precondition: both scenes with unreadable text unticked")
        #expect(!choice.leavesOutTickedScenesText, "scene 4's notices aren't unreadable text")
        #expect(ExportWording.notes(for: choice).isEmpty)

        choice.untickAll()
        #expect(!choice.leavesOutTickedScenesText, "none ticked")
        choice.click(Self.ids[4], .single)
        #expect(choice.leavesOutTickedScenesText, "only a scene with unreadable text ticked")
    }

    @Test func noLineForAStoryWithoutUnreadableText() {
        var choice = Self.choice()
        #expect(!choice.leavesOutTickedScenesText && ExportWording.notes(for: choice).isEmpty, "all ticked")
        choice.click(Self.ids[0], .single)
        #expect(!choice.leavesOutTickedScenesText, "some ticked")
        choice.untickAll()
        #expect(!choice.leavesOutTickedScenesText, "none ticked")
    }

    @Test func aSceneWithOnlyRepairNoticesShowsNoLine() {
        let notices = ErrorTag.allCases.filter { !$0.holdsUnreadableText }
        #expect(notices == [.notice], "every tag but notice is unreadable text")
        let choice = ExportChoice(
            book: Book(
                title: "T", scenes: [Self.scene(0, errors: notices.map { ErrorEntry($0, "repaired") })]))
        #expect(!choice.leavesOutTickedScenesText && ExportWording.notes(for: choice).isEmpty)
    }

    @Test(arguments: ErrorTag.allCases.filter(\.holdsUnreadableText))
    func everyTagButNoticeCountsInAScene(_ tag: ErrorTag) {
        let choice = ExportChoice(
            book: Book(title: "T", scenes: [Self.scene(0, errors: [ErrorEntry(tag, "x")])]))
        #expect(choice.leavesOutTickedScenesText)
        #expect(!choice.leavesOutBookText)
    }

    @Test func theBookLineShowsWhateverIsTicked() {
        var choice = Self.choiceWithUnreadableText(bookErrors: [ErrorEntry(.frontMatter, "colour: blue")])
        #expect(
            ExportWording.notes(for: choice) == [
                ExportWording.scenesTextLeftOut, ExportWording.bookTextLeftOut,
            ])
        choice.click(Self.ids[1], .single)
        choice.click(Self.ids[4], .single)
        #expect(ExportWording.notes(for: choice) == [ExportWording.bookTextLeftOut], "only the book's own")
        choice.untickAll()
        #expect(ExportWording.notes(for: choice) == [ExportWording.bookTextLeftOut], "nothing ticked")
    }

    @Test func theBooksRepairNoticesShowNoLine() {
        let choice = Self.choiceWithUnreadableText(bookErrors: [ErrorEntry(.notice, "The file wasn't UTF-8.")]
        )
        #expect(!choice.leavesOutBookText)
        #expect(ExportWording.notes(for: choice) == [ExportWording.scenesTextLeftOut])
    }

    /// The lines claim the export leaves the entries out: the copy holds none of them.
    @Test func theLinesFollowWhatTheReviewCopyLeavesOut() throws {
        var book = Book(title: "T", scenes: [Self.scene(0, errors: [ErrorEntry(.notice, "repaired")])])
        book.errors = [ErrorEntry(.notice, "repaired")]
        #expect(!ReviewCopy.leavesOutUnreadableText(of: book.scenes[0]), "notices only")
        #expect(!ReviewCopy.leavesOutUnreadableText(ofBookItself: book), "notices only")

        book.scenes[0].errors.append(ErrorEntry(.line, "garbled"))
        book.errors.append(ErrorEntry(.line, "before the first scene"))
        let copy = ReviewCopy(
            projecting: book, chosen: [Self.ids[0]], export: ExportID(rawValue: "e"),
            exported: Timestamp(secondsSince1970: 0, offset: .zero))
        try #require(copy.book.scenes.map(\.id) == [Self.ids[0]], "precondition: the scene is in the copy")
        try #require(
            copy.book.errors.isEmpty && copy.book.scenes[0].errors.isEmpty,
            "precondition: the copy drops the book's and the scene's unreadable lines")
        #expect(ReviewCopy.leavesOutUnreadableText(of: book.scenes[0]))
        #expect(ReviewCopy.leavesOutUnreadableText(ofBookItself: book))
    }

    @Test func aBookWithOneSceneSaysScene() {
        #expect(ExportWording.tickedCount(1, of: 1) == "1 of 1 scene")
    }
}
