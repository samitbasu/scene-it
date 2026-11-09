import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

// A random-edit fuzz of the real page through every path that
// changes its text, and focused cases for the edges it found.

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let otherID = CommentID(rawValue: "01JC4K00000000000000000OTH")
private let other = Comment(
    id: otherID, color: .blue, text: "Other",
    created: Timestamp(Date(timeIntervalSince1970: 1_700_000_100), in: .gmt))

private let fuzzScene: [Paragraph] = [
    [
        Run("The "), Run("letter", color: .red, comments: [noted]), Run(" waited "),
        Run("long", styles: [.italic]),
    ],
    [Run("Dawn.", styles: [.bold]), Run(" Then ", highlight: .green), Run("night", comments: [otherID])],
    [],
    [Run("Last line here.")],
]

private let pieces: [String] = [
    "a", "b", " ", "x y", "\n", "\r\n", "\r", "\u{2028}", "\u{2029}", "\u{0B}", "\u{85}", "\u{201C}q\u{201D}",
    "\u{2014}", "\u{1F30A}", "\u{00E9}", "e\u{0301}", "\t", "\u{FFFC}", "\u{65E5}\u{672C}", "\u{00FF}",
    "line1\nline2", "\n\n",
]

private func lone() -> NSString {
    var unit: unichar = 0xD800
    return NSString(characters: &unit, length: 1)
}

/// What the find bar does for Replace and Replace All: ask, replace in the storage keeping
/// attributes, then announce.
private func finderReplace(_ view: NSTextView, _ range: NSRange, _ string: String) {
    guard view.shouldChangeText(inRanges: [NSValue(range: range)], replacementStrings: [string]) else {
        return
    }
    view.textStorage?.replaceCharacters(in: range, with: string)
    view.didChangeText()
}

/// Where `page` and `model` first differ, in UTF-16 code units; `nil` if they don't.
private func firstDifference(_ page: NSAttributedString, _ model: NSAttributedString) -> String? {
    // Code units, not `String ==`: that compares canonical equivalence, so `é` and `e` +
    // U+0301 would compare equal at different lengths.
    let pageUnits = Array(page.string.utf16)
    let modelUnits = Array(model.string.utf16)
    guard pageUnits == modelUnits else {
        let shared = min(pageUnits.count, modelUnits.count)
        let index = (0..<shared).first { pageUnits[$0] != modelUnits[$0] } ?? shared
        func unit(_ units: [UInt16]) -> String {
            index < units.count ? String(units[index], radix: 16) : "end"
        }
        return "the text differs at \(index): page \(unit(pageUnits)) / model \(unit(modelUnits)) in "
            + "\(page.string.debugDescription) / \(model.string.debugDescription)"
    }
    for index in 0..<page.length {
        let onPage = page.attributes(at: index, effectiveRange: nil)
        let inModel = model.attributes(at: index, effectiveRange: nil)
        if !NSDictionary(dictionary: onPage).isEqual(to: inModel) {
            return "attributes at \(index): page \(onPage) / model \(inModel)"
        }
    }
    return nil
}

private func randomRange(_ length: Int, _ rng: inout SplitMix) -> NSRange {
    let a = Int.random(in: 0...length, using: &rng)
    let b = Int.random(in: 0...length, using: &rng)
    if Bool.random(using: &rng) { return NSRange(location: a, length: 0) }
    return NSRange(location: min(a, b), length: abs(a - b))
}

private func randomText(_ rng: inout SplitMix) -> String {
    (0..<Int.random(in: 1...3, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
}

private final class Fuzz {
    let page: PageHarness
    let pasteboard: NSPasteboard
    var rng: SplitMix
    var log: [String] = []
    /// The first step after which the model wasn't the codec's reading of the page, with the
    /// steps leading to it.
    var bodyMismatch: [String]?
    /// The first step after which the page didn't show exactly what the model holds.
    var mirrorMismatch: [String]?

    init(page: PageHarness, pasteboard: NSPasteboard, seed: UInt64) {
        self.page = page
        self.pasteboard = pasteboard
        rng = SplitMix(state: seed)
    }

    func step() {
        let view = page.page
        let length = page.storage.length
        view.setSelectedRange(randomRange(length, &rng))
        switch Int.random(in: 0..<16, using: &rng) {
        case 0, 1:
            let text = randomText(&rng)
            log.append("insertText(\(text.debugDescription)) at \(view.selectedRange())")
            view.insertText(text, replacementRange: view.selectedRange())
        case 2:
            log.append("deleteBackward at \(view.selectedRange())")
            view.deleteBackward(nil)
        case 3:
            log.append("deleteForward at \(view.selectedRange())")
            view.deleteForward(nil)
        case 4:
            log.append("insertNewline at \(view.selectedRange())")
            view.insertNewline(nil)
        case 5:
            log.append("copy \(view.selectedRange())")
            pasteboard.clearContents()
            _ = view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes)
        case 6:
            log.append("cut \(view.selectedRange())")
            pasteboard.clearContents()
            if view.selectedRange().length > 0 {
                _ = view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes)
                view.delete(nil)
            }
        case 7:
            log.append("paste at \(view.selectedRange()) types \(pasteboard.types ?? [])")
            _ = view.readSelection(from: pasteboard)
        case 8:
            let text = randomText(&rng)
            log.append("paste plain \(text.debugDescription) at \(view.selectedRange())")
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            _ = view.readSelection(from: pasteboard)
        case 9:
            view.breakUndoCoalescing()
            log.append("undo")
            if view.undoManager?.canUndo == true { view.undoManager?.undo() }
        case 10:
            log.append("redo")
            if view.undoManager?.canRedo == true { view.undoManager?.redo() }
        case 11:
            let range = randomRange(length, &rng)
            let text = randomText(&rng)
            log.append("find bar replace \(range) with \(text.debugDescription)")
            finderReplace(view, range, text)
        case 12:
            let text = randomText(&rng)
            let range = view.selectedRange()
            log.append("autocorrect \(range) -> \(text.debugDescription)")
            if range.length > 0 {
                view.handleTextCheckingResults(
                    [NSTextCheckingResult.replacementCheckingResult(range: range, replacementString: text)],
                    forRange: range, types: NSTextCheckingAllTypes, options: [:],
                    orthography: NSOrthography.defaultOrthography(forLanguage: "en"), wordCount: 1)
            }
        case 13:
            let marked = Bool.random(using: &rng) ? "\u{306B}\u{307B}" : "ni"
            log.append("setMarkedText(\(marked.debugDescription)) at \(view.selectedRange())")
            view.setMarkedText(
                marked, selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
        case 14:
            log.append("insert a lone surrogate at \(view.selectedRange())")
            view.insertText(lone(), replacementRange: view.selectedRange())
        default:
            log.append("uppercaseWord at \(view.selectedRange())")
            view.uppercaseWord(nil)
        }
        checkModel()
    }

    /// The model is the codec's reading of the page as soon as the edit returns.
    private func checkModel() {
        let model = page.body()
        if bodyMismatch == nil, RunCodec.body(from: page.storage) != model {
            bodyMismatch =
                log.suffix(12) + ["page: \(page.storage.string.debugDescription)", "model: \(model)"]
        }
    }

    /// The page shows exactly what the model holds once the turn is over.
    func checkPage() {
        guard mirrorMismatch == nil,
            let difference = firstDifference(page.storage, RunCodec.attributedString(forBody: page.body()))
        else { return }
        mirrorMismatch = log.suffix(6) + [difference]
    }
}

/// What the end of an event does to an undo manager that groups by event. A test has no events,
/// so without this everything it does lands in one undo group.
private func endEvent(_ undo: UndoManager) {
    while undo.groupingLevel > 0 { undo.endUndoGrouping() }
}

/// How much the fuzz runs. The gate runs a little; `PAGE_FUZZ_SEEDS` and `PAGE_FUZZ_STEPS` (through
/// xcodebuild, `TEST_RUNNER_PAGE_FUZZ_SEEDS` and `TEST_RUNNER_PAGE_FUZZ_STEPS`) run more.
nonisolated enum PageFuzz {
    static let seeds: [UInt64] = Array(1...UInt64(setting("PAGE_FUZZ_SEEDS", default: 2)))
    static let steps = setting("PAGE_FUZZ_STEPS", default: 200)
    /// Each seed's limit: generous at a tenth of a second a step, and never under two minutes.
    static let minutes = max(2, steps / 600 + 1)

    private static func setting(_ name: String, default value: Int) -> Int {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init).map { max(1, $0) } ?? value
    }
}

@Suite(.serialized, .timeLimit(.minutes(PageFuzz.minutes)))
struct PageFuzzTests {
    /// Each step runs from the run loop, as an event's handling does, never inside a Swift task:
    /// an Objective-C exception raised inside a task's job unwinds past the concurrency
    /// runtime's record of the current executor, and the app crashes at the next isolation
    /// check.
    @Test(arguments: PageFuzz.seeds)
    func randomEditsKeepPageAndModelInStep(seed: UInt64) async throws {
        let one = scene("One", fuzzScene, .withTooEarly)
        var withOther = one
        withOther.comments.append(other)
        try await withPage([withOther, scene("Two", [[Run("Second.")]])]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                page.focusPage(at: 0)
                let fuzz = Fuzz(page: page, pasteboard: pasteboard, seed: seed)
                for _ in 0..<PageFuzz.steps {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        RunLoop.main.perform {
                            MainActor.assumeIsolated { fuzz.step() }
                            done.resume()
                        }
                    }
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        DispatchQueue.main.async {
                            fuzz.checkPage()
                            done.resume()
                        }
                    }
                }
                #expect(fuzz.bodyMismatch == nil, "\(fuzz.bodyMismatch?.joined(separator: "\n") ?? "")")
                #expect(fuzz.mirrorMismatch == nil, "\(fuzz.mirrorMismatch?.joined(separator: "\n") ?? "")")
                #expect(RunCodec.body(from: page.storage) == page.body())
                let scene = try #require(page.book.book.scene(withOther.id))
                #expect(
                    Paragraph.commentIDs(in: scene.body).isSubset(of: Set(scene.comments.map(\.id))),
                    "no dangling comment id")
                _ = try BookFormat.verifiedSerialization(of: page.book.book)
                await eventually { page.book.status == .saved }
                #expect(try bookOnDisk(page.url) == page.book.book)
            }
        }
    }

}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct AdversarialPageTests {
    @Test func manySynchronousKeystrokesThenRender() async throws {
        try await withPage([scene("One", [[Run("Start.")]])]) { page in
            page.focusPage(at: 6)
            for _ in 0..<1500 { page.page.insertText("x", replacementRange: page.page.selectedRange()) }
            #expect(page.window.viewsNeedDisplay, "precondition: the keystrokes are still to be drawn")
            await eventually { !page.window.viewsNeedDisplay }
            #expect(page.body().first?.text.count == 1506)
        }
    }

    /// The backstop for a model changed under the page within the turn of a keystroke, which
    /// SwiftUI's update ordering should make unreachable: the model wins, the page reloads, and
    /// its undo history, which describes the text that's gone, is cleared.
    @Test func aModelChangedInTheSameTurnAsAKeystrokeWinsAndClearsThePagesUndo() async throws {
        try await withPage([scene("One", [[Run("Alpha.")], [Run("Beta.")]])]) { page in
            page.focusPage(at: 6)
            page.page.insertText(" More.", replacementRange: page.page.selectedRange())
            let open = try #require(page.book.openScene)
            page.book.replaceBody(of: open, with: [[Run("Alpha.")], [Run("Gamma.")]])
            page.page.insertText("!", replacementRange: page.page.selectedRange())
            #expect(page.body() == [[Run("Alpha.")], [Run("Gamma.")]], "the model is intact")
            await eventually { page.pageMirrorsModel }
            await eventually { page.page.undoManager?.canUndo == false }
            #expect(page.body() == [[Run("Alpha.")], [Run("Gamma.")]])
        }
    }

    /// ADR 0028: no input method can reach the page or the title, so neither ever holds marked
    /// text.
    @Test func thePageAndTheTitleHaveNoInputContext() async throws {
        try await withPage([scene("One", [[Run("ab")]])]) { page in
            page.focusPage(at: 1)
            #expect(page.window.firstResponder === page.page, "precondition: the page has the keyboard")
            #expect(page.page.inputContext == nil)
            #expect(page.window.makeFirstResponder(page.title))
            let editor = try #require(page.title.currentEditor() as? NSTextView)
            #expect(editor is KeyboardTextView, "the title's own field editor, not the window's")
            #expect(editor.inputContext == nil)
            #expect(page.page.writingToolsBehavior == .none && editor.writingToolsBehavior == .none)
            page.page.writingToolsBehavior = .complete
            #expect(page.page.writingToolsBehavior == .none, "Writing Tools can't be turned back on")
        }
    }

    /// Review S2: the title's correction is one undoable change, so undoing a length-changing
    /// transliteration gives back the title as it was, never the typing's offsets replayed over
    /// the corrected text.
    @Test func undoingATransliteratedTitleGivesBackTheTitle() async throws {
        let one = scene("One", [[Run("First.")]])
        try await withPage([one]) { page in
            #expect(page.window.makeFirstResponder(page.title))
            let editor = try #require(page.title.currentEditor() as? NSTextView)
            editor.setSelectedRange(NSRange(location: 3, length: 0))
            editor.insertText("\u{A9}", replacementRange: editor.selectedRange())
            #expect(editor.string == "One(c)")
            #expect(page.book.book.scene(one.id)?.title.text == "One(c)")
            #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
            let undo = try #require(editor.undoManager)
            undo.undo()
            #expect(editor.string == "One")
            #expect(page.book.book.scene(one.id)?.title.text == "One")
            undo.redo()
            #expect(editor.string == "One(c)")
            #expect(page.book.book.scene(one.id)?.title.text == "One(c)")
        }
    }

    /// Review S3: text the policy changes, replacing a range away from the caret (a spelling
    /// correction, say), leaves the caret where it was in the text around it.
    @Test func aCorrectionAwayFromTheCaretLeavesTheCaretInPlace() async throws {
        try await withPage([scene("One", [[Run("cafe ole")]])]) { page in
            page.focusPage(at: 5)
            page.page.insertText("caf\u{E9}", replacementRange: NSRange(location: 0, length: 4))
            #expect(page.storage.string == "cafe ole")
            #expect(page.page.selectedRange() == NSRange(location: 5, length: 0))
            page.page.insertText("\u{2014}", replacementRange: NSRange(location: 4, length: 1))
            #expect(page.storage.string == "cafe--ole")
            #expect(
                page.page.selectedRange() == NSRange(location: 6, length: 0), "after the dash it replaced")
        }
    }

    @Test func theSelectionFollowsTheTextAroundAnEdit() {
        let edits = [
            KeyboardTextView.Edit(range: NSRange(location: 2, length: 2), length: 5),
            KeyboardTextView.Edit(range: NSRange(location: 8, length: 0), length: 1),
        ]
        let moved = KeyboardTextView.selection(
            [
                NSRange(location: 0, length: 1), NSRange(location: 2, length: 2),
                NSRange(location: 3, length: 3),
                NSRange(location: 8, length: 0), NSRange(location: 9, length: 1),
            ], after: edits)
        #expect(
            moved == [
                NSRange(location: 0, length: 1), NSRange(location: 7, length: 0),
                NSRange(location: 7, length: 2),
                NSRange(location: 12, length: 0), NSRange(location: 13, length: 1),
            ])
    }

    /// Review S4: should any edit skip the veto, the model takes the admitted reading at once
    /// and the page reloads from it.
    @Test func anEditThatSkipsTheVetoIsCorrectedFromTheModel() async throws {
        try await withPage([scene("One", [[Run("ab")]])]) { page in
            page.focusPage(at: 1)
            page.storage.replaceCharacters(in: NSRange(location: 1, length: 0), with: "\u{E9}\u{2022}")
            #expect(page.body() == [[Run("ae*b")]], "the model never holds what the page skipped")
            await eventually { page.storage.string == "ae*b" }
            #expect(page.pageMirrorsModel)
        }
    }

    /// Should anything call `setMarkedText` anyway, its text is typed, through the policy, and
    /// reaches the model at once: there is no composition to wait for.
    @Test func markedTextIsTypedInstead() async throws {
        try await withPage([scene("One", [[Run("ab")]])]) { page in
            await eventually { page.book.status == .saved }
            page.focusPage(at: 1)
            page.page.setMarkedText(
                "ni", selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(!page.page.hasMarkedText())
            #expect(page.body() == [[Run("anib")]])
            #expect(page.book.status == .unsaved, "autosave heard of it in the same turn")
            page.page.setMarkedText(
                "\u{306B}\u{307B}", selectedRange: NSRange(location: 2, length: 0),
                replacementRange: page.page.selectedRange())
            #expect(!page.page.hasMarkedText())
            #expect(page.body() == [[Run("ani[?][?]b")]])
            #expect(page.pageMirrorsModel)
        }
    }

    /// The B1 case (#72) with nothing composing: what was just typed stays in its scene, and the
    /// next scene's text is untouched.
    @Test func typingThenSwitchingScenesKeepsEachScenesText() async throws {
        let one = scene("One", [[Run("ab")]])
        let two = scene("Two", [[Run("Second.")]])
        try await withPage([one, two]) { page in
            page.focusPage(at: 2)
            page.page.insertText("x", replacementRange: page.page.selectedRange())
            page.page.setMarkedText(
                "ni", selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            page.book.select(two.id)
            await eventually { page.storage.string == "Second." }
            page.page.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
            #expect(page.body(one.id) == [[Run("abxni")]])
            #expect(page.body(two.id) == [[Run("ZSecond.")]])
            #expect(page.pageMirrorsModel)
        }
    }

    @Test func aClipWithNothingToPasteFallsBackToThePlainText() async throws {
        try await withPage([scene("One", [[Run("ab")]])]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setData(Data([0xFF, 0x00, 0xFE, 0x42]), forType: .pageClip)
                pasteboard.setString("plain", forType: .string)
                page.focusPage(at: 1)
                #expect(page.page.readSelection(from: pasteboard))
                #expect(page.body() == [[Run("aplainb")]])

                pasteboard.clearContents()
                pasteboard.setData(Data("# Not a book\n\nrandom ```\n## \n".utf8), forType: .pageClip)
                pasteboard.setString("two", forType: .string)
                let clip = try #require(pasteboard.data(forType: .pageClip))
                #expect(PageClip(data: clip)?.lines == [], "precondition: a scene with nothing in it")
                page.page.setSelectedRange(NSRange(location: 0, length: 0))
                #expect(page.page.readSelection(from: pasteboard))
                #expect(page.body() == [[Run("twoaplainb")]])
                #expect(page.pageMirrorsModel)
            }
        }
    }

    @Test func aClipFromAnotherBookWithACollidingCommentIdGetsAFreshId() async throws {
        let destination = scene("One", [[Run("Here "), Run("x", comments: [noted])]], .withTooEarly)
        try await withPage([destination]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                let foreign = BookScene(
                    id: SceneID(rawValue: "01JC4K000000000000000FOREIGN"),
                    modified: Timestamp(.now, in: .current),
                    title: "F", body: [[Run("their", comments: [noted])]],
                    comments: [Comment(id: noted, color: .green, text: "Theirs", created: tooEarly.created)])
                let data = try #require(PageClip([[Run("their", comments: [noted])]], from: foreign).data)
                pasteboard.clearContents()
                pasteboard.setData(data, forType: .pageClip)
                page.focusPage(at: 0)
                #expect(page.page.readSelection(from: pasteboard))
                let pasted = try #require(page.book.book.scene(destination.id))
                #expect(pasted.comments.count == 2)
                #expect(pasted.comments.contains(tooEarly))
            }
        }
    }

    @Test func aClipIsntPastedIntoAReadOnlyBook() async throws {
        try await withPage([scene("Held", [[Run("Kept.")]])], lock: .heldElsewhere) { page in
            try await PageHarness.withPasteboard { pasteboard in
                let held = try #require(page.book.book.scene(page.book.openScene))
                let data = try #require(PageClip([[Run("Kept.")]], from: held).data)
                pasteboard.clearContents()
                pasteboard.setData(data, forType: .pageClip)
                #expect(!page.page.readSelection(from: pasteboard))
                #expect(page.storage.string == "Kept.")
            }
        }
    }

    @Test func typingThenPastingCommentsUndoesInTwoSteps() async throws {
        try await withPage([scene("One", letterScene, .withTooEarly), scene("Two", [[Run("Elsewhere.")]])]) {
            page in
            try await PageHarness.withPasteboard { pasteboard in
                page.window.makeFirstResponder(page.page)
                page.page.setSelectedRange(NSRange(location: 4, length: 6))
                #expect(page.page.writeSelection(to: pasteboard, types: page.page.writablePasteboardTypes))
                let two = try #require(page.book.book.scenes.last?.id)
                page.book.select(two)
                await eventually { page.storage.string == "Elsewhere." }
                page.focusPage(at: 10)
                page.page.insertText(" abc", replacementRange: page.page.selectedRange())
                let undo = try #require(page.page.undoManager)
                endEvent(undo)
                #expect(page.page.readSelection(from: pasteboard))
                undo.undo()
                let afterUndo = try #require(page.book.book.scene(two))
                #expect(
                    afterUndo.body == [[Run("Elsewhere. abc")]],
                    "one undo takes the paste away, not the typing")
                #expect(afterUndo.comments.isEmpty)
                undo.redo()
                let afterRedo = try #require(page.book.book.scene(two))
                #expect(
                    Paragraph.commentIDs(in: afterRedo.body).isSubset(of: Set(afterRedo.comments.map(\.id))))
                #expect(afterRedo.comments.count == 1)
            }
        }
    }

    /// A correction replaces a word in place, as the spelling panel's Change does. (Driving
    /// `handleTextCheckingResults` offscreen applies nothing, so it can't stand in.)
    @Test func correctingACommentedWordKeepsTheComment() async throws {
        try await withPage([scene("One", letterScene, .withTooEarly)]) { page in
            page.focusPage(at: 4)
            let word = NSRange(location: 4, length: 6)
            #expect((page.storage.string as NSString).substring(with: word) == "letter", "precondition")
            page.page.insertText("l\u{2019}tter", replacementRange: word)
            #expect(
                page.body().first == [
                    Run("The "), Run("l'tter", color: .red, comments: [noted]), Run(" waited."),
                ])
            #expect(page.pageMirrorsModel)
        }
    }

    @Test func findAndReplaceThatThePolicyChangesKeepsFormatAndComments() async throws {
        let said: [Paragraph] = [[Run("say "), Run("hi", styles: [.italic], comments: [noted]), Run(" now")]]
        try await withPage([scene("One", said, .withTooEarly)]) { page in
            await eventually { page.book.status == .saved }
            page.focusPage(at: 0)
            let hi = NSRange(location: 4, length: 2)
            #expect((page.storage.string as NSString).substring(with: hi) == "hi", "precondition")
            finderReplace(page.page, hi, "\u{201C}hi\u{201D}")
            #expect(page.book.status == .unsaved)
            #expect(
                page.body() == [
                    [Run("say "), Run("\"hi\"", styles: [.italic], comments: [noted]), Run(" now")]
                ])
            #expect(page.pageMirrorsModel)
        }
    }

    @Test(arguments: ["e\u{0301}", "\u{00E9}"])
    func anAccentedLetterIsThePlainLetterOnThePageAsInTheModel(typed: String) async throws {
        try await withPage([scene("One", [[Run("ab")]])]) { page in
            page.focusPage(at: 1)
            page.page.insertText(typed, replacementRange: page.page.selectedRange())
            #expect(Array(page.storage.string.utf16) == Array("aeb".utf16))
            #expect(page.body() == [[Run("aeb")]])
            #expect(page.page.selectedRange() == NSRange(location: 2, length: 0))
        }
    }

    @Test func aParagraphBreakTypedInBoldIsPlainOnThePageAsInTheModel() async throws {
        try await withPage([scene("One", [[Run("Bold", styles: [.bold])]])]) { page in
            page.focusPage(at: 4)
            #expect(
                page.page.typingAttributes[.font] as? NSFont == ParagraphRole.body.font([.bold]),
                "precondition")
            page.page.insertNewline(nil)
            page.page.insertText("more", replacementRange: page.page.selectedRange())
            #expect(page.body() == [[Run("Bold", styles: [.bold])], [Run("more", styles: [.bold])]])
            #expect(page.pageMirrorsModel)
        }
    }

    /// Smart quotes and dashes turned on (#127): AppKit offers curled quotes and an em dash, the
    /// character policy gives back the straight ones already there, and that's no edit at all:
    /// the book stays saved and Undo undoes the typing, not a substitution.
    @Test func turnedOnSubstitutionsStillGoThroughThePolicy() async throws {
        try await withPage([scene("One", [[Run("ab")]])]) { page in
            let view = page.page
            view.isAutomaticQuoteSubstitutionEnabled = true
            view.isAutomaticDashSubstitutionEnabled = true
            page.focusPage(at: 2)
            let typed = " \"hi\" -- ok"
            view.insertText(typed, replacementRange: view.selectedRange())
            await eventually { page.book.status == .saved }
            let recorder = ReplacementRecorder(view)
            defer { recorder.restore() }
            view.checkTextInDocument(nil)
            let offered = recorder.replacements.joined()
            #expect(offered.contains("\u{201C}"), "precondition: AppKit offered a curled quote")
            #expect(offered.contains("\u{2014}"), "precondition: AppKit offered an em dash")
            #expect(view.string == "ab" + typed)
            #expect(page.body() == [[Run("ab" + typed)]])
            #expect(page.pageMirrorsModel)
            #expect(page.book.status == .saved, "nothing was edited")
            page.book.pageUndo(for: try #require(page.book.openScene)).undo()
            #expect(page.body() == [[Run("ab")]], "Undo undoes the typing")
        }
    }

    @Test func undoRedoAndFindAndReplaceMarkTheBookEditedInTheSameTurn() async throws {
        try await withPage([scene("One", [[Run("one two")]])]) { page in
            page.focusPage(at: 7)
            page.page.insertText(" three", replacementRange: page.page.selectedRange())
            page.page.breakUndoCoalescing()
            await eventually { page.book.status == .saved }
            page.page.undoManager?.undo()
            #expect(page.book.status == .unsaved, "undo")
            await eventually { page.book.status == .saved }
            page.page.undoManager?.redo()
            #expect(page.book.status == .unsaved, "redo")
            await eventually { page.book.status == .saved }
            finderReplace(page.page, NSRange(location: 0, length: 3), "ONE")
            #expect(page.book.status == .unsaved, "find and replace")
        }
    }
}

/// Stands in as a text view's delegate, recording each replacement string AppKit offers before
/// handing everything on to the real delegate, which it puts back when done.
@MainActor
final class ReplacementRecorder: NSObject, NSTextViewDelegate {
    private let view: NSTextView
    /// Set once, as it's made; read by the forwarding AppKit asks for on the main thread.
    nonisolated(unsafe) private let original: (any NSTextViewDelegate)?
    private(set) var replacements: [String] = []

    init(_ view: NSTextView) {
        self.view = view
        original = view.delegate
        super.init()
        view.delegate = self
    }

    func restore() {
        view.delegate = original
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector)
            || MainActor.assumeIsolated { original?.responds(to: aSelector) == true }
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }

    func textView(
        _ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
        replacementStrings: [String]?
    ) -> Bool {
        replacements += replacementStrings ?? []
        return original?.textView?(
            textView, shouldChangeTextInRanges: affectedRanges, replacementStrings: replacementStrings)
            ?? true
    }
}
