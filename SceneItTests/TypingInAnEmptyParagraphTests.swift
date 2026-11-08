import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// Typing "Clown" into the empty line between two paragraphs put "C" on that line and "lown" on
/// the next: the first character restyles its paragraph, break included, while the text storage
/// is processing the edit, which grows the edited range over the break, and the view puts the
/// caret at the end of the edited range.
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
        try await typeClown(into: [[Run("Ert")], [], [Run("I saw teh cat")]], at: 4, reading: "Ert\nClown\nI saw teh cat")
    }

    @Test func aWordTypedAtTheEndOfAMiddleParagraphStaysOnItsLine() async throws {
        try await typeClown(into: [[Run("Ert")], [Run("A ")], [Run("I saw teh cat")]], at: 6, reading: "Ert\nA Clown\nI saw teh cat")
    }

    @Test func aWordTypedIntoAFinalEmptyParagraphStaysOnItsLine() async throws {
        try await typeClown(into: [[Run("Ert")], []], at: 4, reading: "Ert\nClown")
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
                steps.append("\(letter): caret \(page.page.selectedRange()) \(page.storage.string.debugDescription)")
            }
            let log = steps.joined(separator: "\n")
            #expect(page.storage.string == expected, "\(log)")
            #expect(page.page.selectedRange() == NSRange(location: location + 5, length: 0), "\(log)")
        }
    }
}
