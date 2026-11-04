import Testing

@testable import SceneItCore

@MainActor
struct CommentSelectionTests {
    let scene = SceneID(rawValue: "scene")
    let other = SceneID(rawValue: "other")
    let newest = CommentID(rawValue: "c3")
    let middle = CommentID(rawValue: "c2")
    let oldest = CommentID(rawValue: "c1")

    @Test func aClickSelectsTheNewestThenCyclesThroughTheRest() {
        let selection = CommentSelection()
        let covering = [newest, middle, oldest]
        let picks = (0..<4).map { _ in
            selection.click(covering: covering, in: scene)
            return selection.comment(in: scene)
        }
        #expect(picks == [newest, middle, oldest, newest])
    }

    /// The selected comment doesn't cover the clicked spot: start again from the newest there.
    @Test func aClickElsewhereStartsFromTheNewestThere() {
        let selection = CommentSelection()
        selection.select(oldest, in: scene)
        selection.click(covering: [newest, middle], in: scene)
        #expect(selection.comment(in: scene) == newest)
    }

    @Test func aClickOnUncommentedTextChangesNothing() {
        let selection = CommentSelection()
        selection.select(middle, in: scene)
        selection.click(covering: [], in: scene)
        #expect(selection.comment(in: scene) == middle)
    }

    @Test func aCommentTheSceneNoLongerHasIsForgotten() {
        let selection = CommentSelection()
        selection.select(middle, in: scene)
        selection.forget(allBut: [newest, middle], in: scene)
        #expect(selection.comment(in: scene) == middle)
        selection.forget(allBut: [newest], in: other)
        #expect(selection.comment(in: scene) == middle, "another scene's comments don't count")
        selection.forget(allBut: [newest], in: scene)
        #expect(selection.selected == nil)
    }

    /// Another scene's selection is no comment of this one's, so a click here starts afresh.
    @Test func aSelectionBelongsToItsScene() {
        let selection = CommentSelection()
        selection.select(newest, in: other)
        #expect(selection.comment(in: scene) == nil)
        selection.click(covering: [newest, oldest], in: scene)
        #expect(selection.comment(in: scene) == newest)
        selection.deselect()
        #expect(selection.selected == nil)
    }
}
