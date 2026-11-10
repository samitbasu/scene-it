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
        return ExportChoice(story: story)
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

    /// Scenes 2 and 5 hold error entries, as a repaired book's `### Unparsed` sections do.
    static func choiceWithErrors() -> ExportChoice {
        let story = ids.enumerated().map { index, id in
            var scene = BookScene(
                id: id, modified: Timestamp(secondsSince1970: 0, offset: .zero), title: SceneTitle("S"))
            if [1, 4].contains(index) { scene.errors = [ErrorEntry(.line, "garbled \(index)")] }
            return scene
        }
        return ExportChoice(story: story)
    }

    @Test func theNoteShowsWhileATickedSceneHoldsErrorEntries() throws {
        var choice = Self.choiceWithErrors()
        try #require(choice.allTicked, "precondition: all ticked")
        #expect(choice.leavesOutErrors, "all ticked")
        #expect(ExportWording.note(for: choice) == ExportWording.errorsLeftOut)

        choice.click(Self.ids[1], .single)
        #expect(choice.leavesOutErrors, "some ticked: scene 5 still is")
        choice.click(Self.ids[4], .single)
        #expect(Self.ticked(choice) == [1, 3, 4, 6], "precondition: both scenes with entries unticked")
        #expect(!choice.leavesOutErrors, "the scenes with entries are unticked")
        #expect(ExportWording.note(for: choice) == nil)

        choice.untickAll()
        #expect(!choice.leavesOutErrors, "none ticked")
        choice.click(Self.ids[4], .single)
        #expect(choice.leavesOutErrors, "only a scene with entries ticked")
    }

    @Test func noNoteWithoutErrorEntries() {
        var choice = Self.choice()
        #expect(!choice.leavesOutErrors && ExportWording.note(for: choice) == nil, "all ticked")
        choice.click(Self.ids[0], .single)
        #expect(!choice.leavesOutErrors, "some ticked")
        choice.untickAll()
        #expect(!choice.leavesOutErrors, "none ticked")
    }

    @Test func theNoteFollowsWhatTheReviewCopyLeavesOut() {
        var scene = BookScene(
            id: Self.ids[0], modified: Timestamp(secondsSince1970: 0, offset: .zero), title: SceneTitle("S"))
        #expect(!ReviewCopy.leavesOutErrors(of: scene))
        scene.errors = [ErrorEntry(.notice, "repaired"), ErrorEntry(.line, "garbled")]
        #expect(ReviewCopy.leavesOutErrors(of: scene))
        let copy = ReviewCopy(
            projecting: Book(title: "T", scenes: [scene]), chosen: [scene.id],
            export: ExportID(rawValue: "e"),
            exported: Timestamp(secondsSince1970: 0, offset: .zero))
        #expect(copy.book.scenes.map(\.errors) == [[]], "precondition: the copy has none of them")
    }

    @Test func aBookWithOneSceneSaysScene() {
        #expect(ExportWording.tickedCount(1, of: 1) == "1 of 1 scene")
    }
}
