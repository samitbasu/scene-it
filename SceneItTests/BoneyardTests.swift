import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import SceneIt

/// A cut scene holding a note, a comment, tags and its text: everything a cut and a restore keep.
private let brother: BookScene = {
    var brother = scene("The brother", letterScene, .withTooEarly)
    brother.notes = [[Run("Too much like chapter 2.")]]
    brother.tags = ["Pieter", "clue"]
    return brother
}()

/// Moving, cutting and restoring scenes, and deleting them from the Boneyard, in the Scenes sheet
/// of the real window (#29, PLAN §7.2, §7.3): through the drop handlers the sheet's drop zones call,
/// the keys as the window delivers them to the sheet, the tiles' ↩ and Delete Permanently…, and
/// the window's Undo and Redo, with `book.md` read back after each save.
///
/// A drag session can't be made in a test (no input is synthesized), so the drops go through
/// `ScenesActions`, which the zones' `SceneDropDelegate` calls as AppKit reports the drag.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct BoneyardTests {
    @Test func aCardDroppedOnAnotherMovesBeforeItAsOneUndoAndIsSaved() async throws {
        try await withScenesSheet { harness, actions in
            let story = harness.book.book.scenes.map(\.id)
            let provider = actions.beginDrag(.card(story[2]))
            #expect(provider.registeredTypeIdentifiers == [UTType.sceneDrag.identifier])
            #expect(harness.scenes.drop.drag == .card(story[2]))
            #expect(actions.accepts(.card(story[0])) && actions.accepts(.tray))

            actions.enter(.card(story[0]))
            #expect(harness.scenes.drop.slot == .before(story[0]), "the slot shows before the card")
            actions.exit(.card(story[0]))
            actions.enter(.slot)
            #expect(harness.scenes.drop.slot == .before(story[0]), "and stays as the pointer moves onto it")
            #expect(actions.drop(on: .slot))
            #expect(harness.scenes.drop == SceneDropState(), "the drag is over")
            #expect(harness.book.book.scenes.map(\.id) == [story[2], story[0], story[1]])
            #expect(harness.modes.mode == .scenes)

            let move = ScenesWording.undoName(of: .move(story[2], to: .end))
            try await harness.expectUndoMenu(undo: move, redo: nil)
            try harness.undo.undo()
            #expect(harness.book.book.scenes.map(\.id) == story)
            try await harness.expectUndoMenu(undo: nil, redo: move)
            try harness.undo.redo()
            #expect(harness.book.book.scenes.map(\.id) == [story[2], story[0], story[1]])
            await eventually { harness.book.status == .saved }
            #expect(try bookOnDisk(harness.url).scenes.map(\.id) == [story[2], story[0], story[1]])
        }
    }

    /// The open scene, dropped on the tray: it's cut to the front of the Boneyard and stays open
    /// there, with the breadcrumb's "Boneyard ›" and the rail's B.
    @Test func aCardDroppedOnTheTrayIsCutAndStaysOpen() async throws {
        try await withScenesSheet(boneyard: [brother]) { harness, actions in
            let story = harness.book.book.scenes.map(\.id)
            try #require(harness.book.openScene == story[0], "precondition: the first scene is open")
            _ = actions.beginDrag(.card(story[0]))
            actions.enter(.card(story[1]))
            actions.exit(.card(story[1]))
            actions.enter(.tray)
            #expect(harness.scenes.drop.isOverTray && harness.scenes.drop.slot == nil, "the tray lights")
            #expect(actions.drop(on: .tray))
            #expect(harness.book.book.scenes.map(\.id) == [story[1], story[2]])
            #expect(harness.book.book.boneyard.map(\.id) == [story[0], brother.id], "at the front")
            #expect(harness.book.openScene == story[0])
            #expect(
                WindowWording.breadcrumb(bookTitle: "Novel", harness.book.location) == [
                    "Novel", WindowWording.boneyard, "The ferry",
                ])
            #expect(CurrentSceneMark(harness.book.location) == .badge(WindowWording.boneyardBadge))
            #expect(harness.book.manuscriptWordCount == WordCount(words: 10), "the cut scene isn't counted")

            try await harness.expectUndoMenu(undo: ScenesWording.undoName(of: .cut(story[0])), redo: nil)
            try harness.undo.undo()
            #expect(harness.book.book.scenes.map(\.id) == story)
            #expect(harness.book.book.boneyard.map(\.id) == [brother.id])
        }
    }

    @Test func aTileIsRestoredWhereItsDroppedOrByItsArrowAtTheEnd() async throws {
        try await withScenesSheet(boneyard: [brother]) { harness, actions in
            let story = harness.book.book.scenes.map(\.id)
            let structure = harness.book.structureUndo
            asSeparateEvents(structure) {
                anEvent(structure) {
                    _ = actions.beginDrag(.tile(brother.id))
                    #expect(!actions.accepts(.tray), "a tile isn't cut again")
                    actions.enter(.tray)
                    #expect(!harness.scenes.drop.isOverTray)
                    actions.exit(.tray)
                    actions.enter(.card(story[1]))
                    #expect(actions.drop(on: .card(story[1])))
                }
                #expect(harness.book.book.scenes.map(\.id) == [story[0], brother.id, story[1], story[2]])
                #expect(harness.book.book.boneyard.isEmpty)
                #expect(
                    structure.undoActionName == ScenesWording.undoName(of: .restore(brother.id, to: .end)))
                structure.undo()
                #expect(harness.book.book.boneyard.map(\.id) == [brother.id])

                anEvent(structure) {
                    _ = actions.beginDrag(.tile(brother.id))
                    actions.enter(.end)
                    #expect(harness.scenes.drop.slot == .end, "the slot shows after the last card")
                    #expect(actions.drop(on: .end))
                }
                #expect(harness.book.book.scenes.map(\.id) == story + [brother.id])
                structure.undo()
                anEvent(structure) { #expect(actions.restoreToEnd(brother.id)) }
                #expect(harness.book.book.scenes.map(\.id) == story + [brother.id])
                structure.undo()
                #expect(harness.book.book.scenes.map(\.id) == story)
            }
        }
    }

    /// The acceptance test (#29): a cut and a restore keep a scene's notes, comments and tags, in
    /// the book and in `book.md`.
    @Test func cutAndRestoreKeepNotesCommentsAndTagsInTheFile() async throws {
        try await withScenesSheet(boneyard: [brother]) { harness, actions in
            let held = try #require(harness.book.book.scene(brother.id))
            try #require(
                !held.notes.isEmpty && !held.comments.isEmpty && !held.tags.isEmpty,
                "precondition: the scene holds a note, a comment and tags")
            #expect(actions.restoreToEnd(brother.id))
            await eventually { harness.book.status == .saved }
            #expect(try bookOnDisk(harness.url).scenes.last.map(Kept.init) == Kept(held))

            _ = actions.beginDrag(.card(brother.id))
            actions.enter(.tray)
            #expect(actions.drop(on: .tray))
            await eventually { harness.book.status == .saved }
            let onDisk = try bookOnDisk(harness.url)
            #expect(onDisk.boneyard.first.map(Kept.init) == Kept(held))
            #expect(onDisk.boneyard.first?.comments == [tooEarly])
            #expect(onDisk.boneyard.first?.tags == ["Pieter", "clue"])
            #expect(harness.book.book.boneyard.first == held, "in the book, all of it")
        }
    }

    @Test func deletingPermanentlyAsksThenHidesTheSceneAndUndoBringsItBack() async throws {
        let prompts = AnsweringPrompts([DeleteChoice.cancel, DeleteChoice.delete])
        try await withScenesSheet(
            boneyard: [brother], books: BookController(role: .testHost, prompts: prompts)
        ) {
            harness, actions in
            harness.book.select(brother.id)
            await actions.deletePermanently(brother.id)
            #expect(prompts.titles == [BoneyardWording.confirmDelete(brother).title])
            #expect(harness.book.book.boneyard.map(\.id) == [brother.id], "Cancel keeps it")

            await actions.deletePermanently(brother.id)
            #expect(prompts.titles.count == 2)
            #expect(harness.book.book.boneyard.isEmpty)
            #expect(harness.book.book.scene(brother.id) == nil, "the writer can't see it")
            #expect(harness.book.openScene == nil && harness.book.location == .noScene, "no scene is open")
            #expect(CurrentSceneMark(harness.book.location) == .unavailable)
            await eventually { harness.book.status == .saved }
            let saved = String(
                decoding: try Data(contentsOf: harness.url.appending(path: "book.md")), as: UTF8.self)
            #expect(saved.contains("# Deleted\n\n## The brother\n"), "kept in the file (ADR 0031)")

            try await harness.expectUndoMenu(undo: BoneyardWording.deleteUndoName, redo: nil)
            try harness.undo.undo()
            #expect(harness.book.book.boneyard.map(\.id) == [brother.id])
        }
    }

    /// The arrows as the window delivers them to the sheet: the first puts the focus on the open
    /// scene's card, the next move it; with Option they move the card, stopping at the ends;
    /// Delete cuts the focused card; Return opens it.
    @Test func theKeysFocusMoveCutAndOpenCards() async throws {
        try await withScenesSheet { harness, actions in
            let story = harness.book.book.scenes.map(\.id)
            await eventually { harness.window.firstResponder is UndoFocusView }
            try #require(
                harness.window.firstResponder is UndoFocusView, "precondition: the sheet has the keys")
            let structure = harness.book.structureUndo
            try asSeparateEvents(structure) {
                try press(.arrow(.right), in: harness.window)
                #expect(harness.scenes.focused == story[0], "the open scene's card")
                try press(.arrow(.right), in: harness.window)
                #expect(harness.scenes.focused == story[1])
                try press(.arrow(.down), in: harness.window)
                #expect(harness.scenes.focused == story[1], "one row: nothing below")

                try anEvent(structure) { try press(.optionArrow(.left), in: harness.window) }
                #expect(harness.book.book.scenes.map(\.id) == [story[1], story[0], story[2]])
                #expect(harness.scenes.focused == story[1], "the focus moves with the card")
                try anEvent(structure) { try press(.optionArrow(.left), in: harness.window) }
                #expect(harness.book.book.scenes.map(\.id) == [story[1], story[0], story[2]], "at the start")
                try anEvent(structure) { try press(.optionArrow(.right), in: harness.window) }
                try anEvent(structure) { try press(.optionArrow(.right), in: harness.window) }
                #expect(harness.book.book.scenes.map(\.id) == [story[0], story[2], story[1]])
                structure.undo()
                structure.undo()
                #expect(harness.book.book.scenes.map(\.id) == [story[1], story[0], story[2]])

                try anEvent(structure) { try press(.delete, in: harness.window) }
                #expect(harness.book.book.scenes.map(\.id) == [story[0], story[2]])
                #expect(harness.book.book.boneyard.map(\.id) == [story[1]])
                #expect(harness.scenes.focused == story[0], "the focus goes to the next card")
                #expect(structure.undoActionName == ScenesWording.undoName(of: .cut(story[1])))
                structure.undo()
                #expect(harness.book.book.scenes.map(\.id) == [story[1], story[0], story[2]])
            }
            try press(.arrow(.right), in: harness.window)
            #expect(harness.scenes.focused == story[2])
            try press(.return, in: harness.window)
            #expect(harness.book.openScene == story[2])
            await eventually { harness.modes.mode == .page }
        }
    }

    /// Return in a new card's title field, or Esc in a card's + tag field, gives the keys back to
    /// the sheet.
    @Test func closingACardsFieldGivesTheSheetTheKeysAgain() async throws {
        try await withScenesSheet { harness, actions in
            let added = try #require(actions.add(.atEnd))
            await eventually { harness.window.firstResponder is NSTextView }
            let editor = try #require(
                harness.window.firstResponder as? NSTextView, "precondition: typing a title")
            editor.insertText("Fog", replacementRange: editor.selectedRange())
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            await eventually { harness.window.firstResponder is UndoFocusView }
            #expect(harness.window.firstResponder is UndoFocusView)
            try press(.arrow(.right), in: harness.window)
            #expect(harness.scenes.focused == added, "the open scene's card: the new one")

            actions.startTagging(added)
            await eventually { harness.window.firstResponder is NSTextView }
            try press(.escape, in: harness.window)
            await eventually {
                harness.scenes.tagging == nil && harness.window.firstResponder is UndoFocusView
            }
            #expect(harness.window.firstResponder is UndoFocusView)
            #expect(harness.modes.mode == .scenes)
        }
    }

    @Test func aReadOnlyBookMovesCutsRestoresAndDeletesNothing() async throws {
        try await withScenesSheet(boneyard: [brother], lock: .heldElsewhere) { harness, actions in
            let before = harness.book.book
            _ = actions.beginDrag(.card(before.scenes[0].id))
            #expect(!actions.accepts(.tray) && !actions.accepts(.card(before.scenes[1].id)))
            #expect(!actions.drop(on: .tray))
            #expect(!actions.restoreToEnd(brother.id))
            await actions.deletePermanently(brother.id)
            #expect(actions.handle(.focus(.right)) == .handled, "the keys still move the focus")
            #expect(actions.handle(.move(.right)) == .passedOn)
            #expect(actions.handle(.cut) == .passedOn)
            #expect(harness.book.book == before)
            actions.open(brother.id)
            #expect(harness.book.openScene == brother.id, "a tile still opens its scene")
        }
    }
}

/// What a scene holds that the writer wrote, as the file keeps it (its time to the second).
private struct Kept: Equatable {
    let id: SceneID
    let title: SceneTitle
    let body: [Paragraph]
    let notes: [Paragraph]
    let comments: [CommentID]
    let tags: [String]

    init(_ scene: BookScene) {
        id = scene.id
        title = scene.title
        body = scene.body
        notes = scene.notes
        comments = scene.comments.map(\.id)
        tags = scene.tags
    }
}

/// Answers each question with the next of `answers`, keeping the titles asked.
private final class AnsweringPrompts: StorePrompts {
    private var answers: [any Hashable & Sendable]
    private(set) var titles: [String] = []

    init(_ answers: [any Hashable & Sendable]) {
        self.answers = answers
    }

    func ask<Choice>(_ alert: WriterAlert<Choice>) async -> Choice {
        titles.append(alert.title)
        guard !answers.isEmpty, let answer = answers.removeFirst() as? Choice else { return alert.choices[0] }
        return answer
    }

    func tell(_ notice: Notice) async {
        titles.append(notice.title)
    }
}
