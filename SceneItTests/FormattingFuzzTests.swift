import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// How much the formatting fuzz runs. The gate runs a little; `FORMAT_FUZZ_SEEDS` and
/// `FORMAT_FUZZ_STEPS` (through xcodebuild, `TEST_RUNNER_FORMAT_FUZZ_SEEDS` and
/// `TEST_RUNNER_FORMAT_FUZZ_STEPS`) run more.
nonisolated enum FormatFuzz {
    static let seeds: [UInt64] = Array(1...UInt64(setting("FORMAT_FUZZ_SEEDS", default: 2)))
    static let steps = setting("FORMAT_FUZZ_STEPS", default: 40)
    /// Each seed's limit: generous at half a second a step, and never under two minutes.
    static let minutes = max(2, steps / 120 + 1)

    private static func setting(_ name: String, default value: Int) -> Int {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init).map { max(1, $0) } ?? value
    }
}

/// Random formatting commands on random selections of the real page, each checked against an
/// oracle: the controls' states, the text and comments untouched, page and model and `book.md`
/// in step, the typing format at a caret, and undo and redo exact.
@Suite(.serialized, .timeLimit(.minutes(FormatFuzz.minutes)))
struct FormattingFuzzTests {
    @Test(arguments: FormatFuzz.seeds)
    func randomFormattingKeepsTheTextAndUndoesExactly(seed: UInt64) async throws {
        var random = SplitMix(state: seed)
        try await withPage([scene("One", fuzzBody, .withTooEarly)]) { page in
            await eventually { page.book.status == .saved }
            page.focusPage(at: 0)
            let undo = try #require(page.page.undoManager)
            await eventually { undo.groupingLevel == 0 }
            let text = page.page.string
            let length = (text as NSString).length
            let breaks = (0..<length).filter { (text as NSString).character(at: $0) == 10 }
            let original = page.body()
            let originalComments = Paragraph.commentIDs(in: original)
            var caretChecks = 0
            var selectionSteps = 0

            @MainActor func expectStatesMatchTheOracle(_ label: String) {
                let ranges = page.page.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
                guard !ranges.isEmpty else { return }
                let formats = characterFormats(page.body())
                let selected = ranges.flatMap { ($0.location..<$0.upperBound).compactMap { formats[$0] } }
                for command in allCommands {
                    #expect(
                        page.formatting.state(of: command) == oracleState(selected, command),
                        "\(label) \(command)")
                }
            }

            for step in 0..<FormatFuzz.steps {
                let kind = Int.random(in: 0..<7, using: &random)
                let ranges = randomSelection(kind, length: length, breaks: breaks, using: &random)
                let command = allCommands.randomElement(using: &random)!
                let before = page.body()
                let beforeFormats = characterFormats(before)
                await inAnEvent(undo) {
                    if kind == 1 {
                        page.page.selectAll(nil)
                    } else {
                        page.page.selectedRanges = ranges.map(NSValue.init(range:))
                    }
                }
                let selection = page.page.selectedRanges.map(\.rangeValue)
                let isCaret = selection.allSatisfy { $0.length == 0 }
                expectStatesMatchTheOracle("step \(step), before")
                let selected = Set(selection.flatMap { $0.location..<$0.upperBound })
                let selectedFormats = selected.sorted().compactMap { beforeFormats[$0] }
                let state = page.formatting.state(of: command)
                await inAnEvent(undo) { page.formatting.perform(command) }

                #expect(page.page.string == text, "step \(step): the text is unchanged")
                #expect(page.pageMirrorsModel, "step \(step): the page is the codec's rendering of the model")
                #expect(Paragraph.commentIDs(in: page.body()) == originalComments, "step \(step)")
                #expect(throws: Never.self) { try BookFormat.verifiedSerialization(of: page.book.book) }

                if isCaret {
                    #expect(page.body() == before, "step \(step): a caret leaves the text alone")
                    let typing = page.page.typingAttributes
                    #expect(
                        NSDictionary(dictionary: typing).isEqual(
                            to: ParagraphRole.body.attributes(normalizing: typing)),
                        "step \(step): the typing attributes are a run's")
                    #expect(typing[.comments] == nil)
                    guard caretChecks < 10 else { continue }
                    caretChecks += 1
                    let at = selection[0].location
                    var predicted: [FormattingCommand: ControlState] = [:]
                    for command in allCommands { predicted[command] = page.formatting.state(of: command) }
                    #expect(!predicted.values.contains(.mixed), "a caret is never mixed")
                    await inAnEvent(undo) {
                        page.page.insertText("q", replacementRange: page.page.selectedRange())
                    }
                    let typed = try #require(characterFormats(page.body())[at])
                    for command in allCommands {
                        #expect(
                            predicted[command] == (typed.has(command) ? .on : .off),
                            "step \(step): the caret showed \(command) for what typing gives")
                    }
                    #expect(typed.comments.isEmpty)
                    await undoInAnEvent(undo)
                    #expect(page.body() == before, "step \(step): the typing undone")
                } else {
                    selectionSteps += 1
                    let expected = oracleState(selectedFormats, command)
                    #expect(state == expected, "step \(step)")
                    let after = characterFormats(page.body())
                    for index in after.indices {
                        if selected.contains(index), let format = beforeFormats[index] {
                            #expect(
                                after[index] == format.applying(command, to: expected),
                                "step \(step) at \(index)")
                        } else {
                            #expect(after[index] == beforeFormats[index], "step \(step): outside at \(index)")
                        }
                    }
                    if !selectedFormats.isEmpty {
                        let now = page.formatting.state(of: command)
                        switch command {
                        case .toggle: #expect(now == (expected == .on ? .off : .on), "step \(step): toggled")
                        default: #expect(now == .on, "step \(step): colored")
                        }
                    }
                    expectStatesMatchTheOracle("step \(step), after")
                    let formatted = page.body()
                    await undoInAnEvent(undo)
                    #expect(page.body() == before, "step \(step): undo restores")
                    #expect(page.pageMirrorsModel, "step \(step): undo")
                    expectStatesMatchTheOracle("step \(step), after undo")
                    await undoInAnEvent(undo, .redo)
                    #expect(page.body() == formatted, "step \(step): redo")
                }
            }
            #expect(selectionSteps > FormatFuzz.steps / 3, "precondition: enough commands on selections")

            page.store.saveNow()
            await eventually { page.book.status == .saved }
            #expect(try bookOnDisk(page.url).scenes.first?.body == page.body())
            let saved = try String(contentsOf: page.url.appending(path: "book.md"), encoding: .utf8)
            #expect(!saved.contains("- color black"), "decision 0013: black is no color")

            var undos = 0
            while page.body() != original, undos < 10 * FormatFuzz.steps {
                await undoInAnEvent(undo)
                undos += 1
                #expect(page.page.string == text)
                #expect(page.pageMirrorsModel)
            }
            #expect(page.body() == original, "undoing every command restores the scene exactly")
        }
    }
}

// MARK: The oracle

/// A character's format.
private struct CharacterFormat: Hashable {
    var styles: Set<TextStyle>
    var color: TextColor?
    var highlight: HighlightColor?
    var comments: Set<CommentID>

    func has(_ command: FormattingCommand) -> Bool {
        switch command {
        case .toggle(let style): styles.contains(style)
        case .textColor(let color): self.color == TextColor(color)
        case .highlight(let highlight): self.highlight == highlight
        }
    }

    func applying(_ command: FormattingCommand, to state: ControlState) -> Self {
        var format = self
        switch command {
        case .toggle(let style):
            if state == .on { format.styles.remove(style) } else { format.styles.insert(style) }
        case .textColor(let color): format.color = TextColor(color)
        case .highlight(let highlight): format.highlight = highlight
        }
        return format
    }
}

/// One entry per UTF-16 unit of the page's text; `nil` for a line break.
private func characterFormats(_ body: [Paragraph]) -> [CharacterFormat?] {
    var formats: [CharacterFormat?] = []
    for (index, paragraph) in body.enumerated() {
        if index > 0 { formats.append(nil) }
        for run in paragraph.runs {
            let format = CharacterFormat(
                styles: run.styles, color: run.color, highlight: run.highlight, comments: run.comments)
            formats += Array(repeating: format, count: run.text.utf16.count)
        }
    }
    return formats
}

private func oracleState(_ formats: [CharacterFormat], _ command: FormattingCommand) -> ControlState {
    let distinct = Set(formats)
    let having = distinct.count { $0.has(command) }
    if having == 0 { return .off }
    return having == distinct.count ? .on : .mixed
}

private let allCommands: [FormattingCommand] =
    TextStyle.allCases.map(FormattingCommand.toggle) + FormattingCommand.textColors
    + FormattingCommand.highlights

private let fuzzBody: [Paragraph] = [
    [
        Run("The "), Run("letter", color: .red, comments: [noted]), Run(" waited ", styles: [.bold]),
        Run("softly", styles: [.italic], highlight: .green),
    ],
    [],
    [Run("Dawn came", styles: [.strike], color: .purple), Run(" slow.")],
    [Run("End.", comments: [noted])],
]

/// A caret, everything, up to a line break, two ranges, a line break alone, or any range.
private func randomSelection(
    _ kind: Int, length: Int, breaks: [Int], using random: inout SplitMix
) -> [NSRange] {
    switch kind {
    case 0: return [NSRange(location: Int.random(in: 0...length, using: &random), length: 0)]
    case 1: return [NSRange(location: 0, length: length)]
    case 2:
        let end = breaks.randomElement(using: &random)! + 1
        let start = Int.random(in: 0..<end, using: &random)
        return [NSRange(location: start, length: end - start)]
    case 3:
        let a = Int.random(in: 0..<(length / 2), using: &random)
        let b = Int.random(in: (length / 2 + 1)..<length, using: &random)
        return [
            NSRange(location: a, length: Int.random(in: 1...(length / 2 - a), using: &random)),
            NSRange(location: b, length: Int.random(in: 1...(length - b), using: &random)),
        ]
    case 4: return [NSRange(location: breaks.randomElement(using: &random)!, length: 1)]
    default:
        let a = Int.random(in: 0..<length, using: &random)
        let b = Int.random(in: (a + 1)...length, using: &random)
        return [NSRange(location: a, length: b - a)]
    }
}

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: Events

/// One event: `body` from the run loop, never inside a Swift task (an Objective-C exception
/// there would unwind past the concurrency runtime), in an undo group of its own, as AppKit
/// makes around each event.
@MainActor
func inAnEvent(_ undo: UndoManager, _ body: @escaping @MainActor () -> Void) async {
    await fromTheRunLoop {
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
        undo.groupsByEvent = true
    }
}

enum UndoDirection {
    case undo, redo
}

@MainActor
func undoInAnEvent(_ undo: UndoManager, _ direction: UndoDirection = .undo) async {
    await fromTheRunLoop {
        switch direction {
        case .undo: undo.undo()
        case .redo: undo.redo()
        }
    }
}

@MainActor
private func fromTheRunLoop(_ body: @escaping @MainActor () -> Void) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        RunLoop.main.perform {
            MainActor.assumeIsolated(body)
            done.resume()
        }
    }
}
