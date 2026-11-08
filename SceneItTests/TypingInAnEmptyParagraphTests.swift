import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// An edit that changes what a paragraph holds (empty or text) changes its style, break
/// included, and the caret stays where the edit left it (#133): restyling while the storage
/// processes the edit would grow the edited range over the break, and the view puts the caret
/// at the end of the edited range.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct TypingInAnEmptyParagraphTests {
    @Test func theCaretStaysAfterACharacterTypedIntoAnEmptyParagraphBeforeAnother() async throws {
        try await withPage([scene("One", [[Run("Ert")], [], [Run("I saw the cat")]])]) { page in
            #expect(page.storage.string == "Ert\n\nI saw the cat", "precondition")
            page.focusPage(at: 4)
            page.page.insertText("C", replacementRange: page.page.selectedRange())
            #expect(page.storage.string == "Ert\nC\nI saw the cat")
            #expect(page.page.selectedRange() == NSRange(location: 5, length: 0))
        }
    }

    @Test func aWordTypedIntoAnEmptyParagraphBetweenTwoStaysOnItsLine() async throws {
        try await typeClown(
            into: [[Run("Ert")], [], [Run("I saw teh cat")]], at: 4, reading: "Ert\nClown\nI saw teh cat")
    }

    @Test func aWordTypedAtTheEndOfAMiddleParagraphStaysOnItsLine() async throws {
        try await typeClown(
            into: [[Run("Ert")], [Run("A ")], [Run("I saw teh cat")]], at: 6,
            reading: "Ert\nA Clown\nI saw teh cat")
    }

    @Test func aWordTypedIntoAFinalEmptyParagraphStaysOnItsLine() async throws {
        try await typeClown(into: [[Run("Ert")], []], at: 4, reading: "Ert\nClown")
    }

    @Test func theFirstCharacterTypedIntoAnEmptyParagraphGivesItTheStyleOfText() async throws {
        try await withPage([scene("One", [[Run("Ert")], [], [Run("I saw the cat")]])]) { page in
            #expect(
                paragraphStyle(of: page, at: 4) == ParagraphRole.body.paragraphStyle(for: .empty),
                "precondition")
            page.focusPage(at: 4)
            page.page.insertText("C", replacementRange: page.page.selectedRange())
            #expect(paragraphStyle(of: page, at: 4) == ParagraphRole.body.paragraphStyle(for: .text))
            #expect(
                paragraphStyle(of: page, at: 5) == ParagraphRole.body.paragraphStyle(for: .text), "its break")
            #expect(page.pageMirrorsModel)
        }
    }

    @Test func aReturnBeforeAnotherParagraphLeavesTheCaretOnTheNewEmptyLine() async throws {
        try await withPage([scene("One", [[Run("Ert")], [Run("I saw the cat")]])]) { page in
            page.focusPage(at: 3)
            page.page.insertNewline(nil)
            #expect(page.storage.string == "Ert\n\nI saw the cat")
            #expect(page.page.selectedRange() == NSRange(location: 4, length: 0))
            #expect(paragraphStyle(of: page, at: 4) == ParagraphRole.body.paragraphStyle(for: .empty))
            #expect(page.pageMirrorsModel)
        }
    }

    @Test func deletingAParagraphsOnlyCharacterLeavesTheCaretOnItsEmptyLine() async throws {
        try await withPage([scene("One", [[Run("Ert")], [Run("C")], [Run("I saw the cat")]])]) { page in
            page.focusPage(at: 5)
            page.page.deleteBackward(nil)
            #expect(page.storage.string == "Ert\n\nI saw the cat")
            #expect(page.page.selectedRange() == NSRange(location: 4, length: 0))
            #expect(paragraphStyle(of: page, at: 4) == ParagraphRole.body.paragraphStyle(for: .empty))
            #expect(page.pageMirrorsModel)
        }
    }

    @Test func undoAndRedoOfTypingIntoAnEmptyParagraphRestoreItsTextAndStyle() async throws {
        try await withPage([scene("One", [[Run("Ert")], [], [Run("I saw the cat")]])]) { page in
            let undo = try #require(page.page.undoManager)
            #expect(!undo.canUndo, "precondition")
            page.focusPage(at: 4)
            for letter in "Clown" {
                page.page.insertText(String(letter), replacementRange: page.page.selectedRange())
            }
            page.page.breakUndoCoalescing()
            undo.undo()
            #expect(!undo.canUndo, "the restyle added no step of its own")
            #expect(page.page.selectedRange() == NSRange(location: 4, length: 0))
            #expect(paragraphStyle(of: page, at: 4) == ParagraphRole.body.paragraphStyle(for: .empty))
            #expect(page.storage.string == "Ert\n\nI saw the cat")
            #expect(page.body() == [[Run("Ert")], [], [Run("I saw the cat")]])
            #expect(page.pageMirrorsModel)
            undo.redo()
            #expect(!undo.canRedo)
            #expect(paragraphStyle(of: page, at: 4) == ParagraphRole.body.paragraphStyle(for: .text))
            #expect(page.storage.string == "Ert\nClown\nI saw the cat")
            #expect(page.pageMirrorsModel)
        }
    }

    @Test func linesPastedIntoAnEmptyParagraphAreEachStyledForWhatTheyHold() async throws {
        try await withPage([scene("One", [[Run("Ert")], [], [Run("I saw the cat")]])]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("Two\n\nLines", forType: .string)
                page.focusPage(at: 4)
                #expect(page.page.readSelection(from: pasteboard))
                #expect(page.storage.string == "Ert\nTwo\n\nLines\nI saw the cat")
                #expect(page.page.selectedRange() == NSRange(location: 14, length: 0))
                #expect(paragraphStyle(of: page, at: 8) == ParagraphRole.body.paragraphStyle(for: .empty))
                #expect(page.pageMirrorsModel)
            }
        }
    }

    @Test func aWordTypedIntoAnEmptyParagraphOfTheNotesStaysOnItsLine() async throws {
        var withNotes = scene("One", [[Run("The ferry left.")]])
        withNotes.notes = [[Run("Ert")], [], [Run("I saw teh cat")]]
        try await withPage([withNotes]) { page in
            let notes = try await page.showNotes()
            page.focusNotes(notes, at: 4)
            for letter in "Clown" {
                notes.insertText(String(letter), replacementRange: notes.selectedRange())
            }
            #expect(notes.string == "Ert\nClown\nI saw teh cat")
            #expect(notes.selectedRange() == NSRange(location: 9, length: 0))
            #expect(page.notesMirrorModel(notes))
        }
    }

    /// Types "Clown" a letter at a time, letting the run loop turn between letters so continuous
    /// spell checking can run, as it does between real keystrokes.
    private func typeClown(into body: [Paragraph], at location: Int, reading expected: String) async throws {
        try await withPage([scene("One", body)]) { page in
            #expect(page.page.isContinuousSpellCheckingEnabled, "precondition")
            page.focusPage(at: location)
            var steps: [String] = []
            for letter in "Clown" {
                page.page.insertText(String(letter), replacementRange: page.page.selectedRange())
                try await Task.sleep(for: .milliseconds(200))
                steps.append(
                    "\(letter): caret \(page.page.selectedRange()) \(page.storage.string.debugDescription)")
            }
            let log = steps.joined(separator: "\n")
            #expect(page.storage.string == expected, "\(log)")
            #expect(page.page.selectedRange() == NSRange(location: location + 5, length: 0), "\(log)")
        }
    }
}

@MainActor private func paragraphStyle(of page: PageHarness, at index: Int) -> NSParagraphStyle? {
    page.storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
}
