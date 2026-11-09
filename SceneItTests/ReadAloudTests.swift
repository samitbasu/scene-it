import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// Read aloud (PLAN §10.3) in a window over a test-host book, whose synthesizer is a
/// `RecordedSpeech`: nothing is ever heard, and each test plays the synthesizer's events itself.
private let ferryText = "Mara watched the ferry. The tide was already turning. Nobody met her."
private let ferry = scene("The ferry", [[Run(ferryText)], [Run("Dawn came late.")]])
private let station = scene("The station", [[Run("The train was gone.")]])

extension PageHarness {
    var speech: RecordedSpeech {
        get throws { try #require(readAloud.speech as? RecordedSpeech) }
    }

    func select(_ text: String) throws {
        let range = (storage.string as NSString).range(of: text)
        try #require(range.location != NSNotFound, "precondition: the page shows \"\(text)\"")
        page.setSelectedRange(range)
    }

    func range(of text: String) -> NSRange {
        (storage.string as NSString).range(of: text)
    }

    /// Starts reading `text`, selected on the page, and checks it's being read.
    func startReading(_ text: String) throws {
        try select(text)
        #expect(readAloud.control == .read, "precondition: there's a selection to read")
        readAloud.press()
        try #require(readAloud.control == .stop, "precondition: reading")
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ReadAloudTests {
    @Test func theButtonReadsOnlyWithASelectionAndStopsWhileReading() async throws {
        try await withPage([ferry]) { page in
            page.focusPage(at: 3)
            #expect(page.readAloud.control == .unavailable, "a caret is no selection")
            try page.select("the ferry")
            #expect(page.readAloud.control == .read)
            page.page.setSelectedRange(NSRange(location: 5, length: 0))
            #expect(page.readAloud.control == .unavailable)

            try page.startReading("watched the ferry. The tide")
            #expect(page.readAloud.control == .stop)
            page.readAloud.press()
            #expect(page.readAloud.control == .read, "■ stops; the selection is still there to read")
            #expect(try page.speech.stops == 1)
        }
    }

    /// The selection alone, in the system voice at 0.5 (ADR 0044) unless the preferences say
    /// otherwise.
    @Test func itSpeaksTheSelectionInThePreferredVoiceAndRate() async throws {
        try await withPage([ferry]) { page in
            page.focusPage(at: 0)
            try page.startReading("watched the ferry. The tide")
            page.readAloud.press()
            let zoe = try #require(VoiceIdentifier("com.apple.voice.premium.en-US.Zoe"))
            page.preferences.setReadAloudVoice(zoe)
            page.preferences.setReadAloudRate(SpeechRate(clamping: 0.4))
            try page.startReading("Dawn came")

            #expect(
                try page.speech.requests == [
                    SpeechRequest(text: "watched the ferry. The tide", voice: nil, rate: .standard),
                    SpeechRequest(text: "Dawn came", voice: zoe, rate: SpeechRate(clamping: 0.4)),
                ])
        }
    }

    /// Each word the synthesizer is about to speak highlights its sentence, on the page alone:
    /// the text storage, the model and the file never change.
    @Test func theSentenceBeingReadIsHighlightedForDisplayOnly() async throws {
        try await withPage([ferry]) { page in
            await eventually { page.book.status == .saved }
            let before = try #require(page.storage.copy() as? NSAttributedString)
            page.focusPage(at: 0)
            try page.startReading("watched the ferry. The tide was already turning. Nobody")
            let speech = try page.speech
            let utterance = try #require(speech.requests.last?.text) as NSString

            speech.report(.willSpeak(utterance.range(of: "ferry")))
            #expect(page.page.spoken == [page.range(of: "watched the ferry.")], "from where reading starts")
            speech.report(.willSpeak(utterance.range(of: "already")))
            #expect(page.page.spoken == [page.range(of: "The tide was already turning.")])
            speech.report(.willSpeak(utterance.range(of: "Nobody")))
            #expect(page.page.spoken == [page.range(of: "Nobody")], "only as far as the selection")

            #expect(page.storage.isEqual(to: before), "the highlight never reaches the storage")
            #expect(page.pageMirrorsModel)
            #expect(page.book.status == .saved, "nothing to save")

            speech.report(.ended)
            #expect(page.readAloud.control == .read, "the end of the selection ends the reading")
            #expect(page.page.spoken.isEmpty)
        }
    }

    /// A read-only book can be read (PLAN §7.1), though its page can't be formatted.
    @Test func aReadOnlyBookCanBeRead() async throws {
        try await withPage([ferry], lock: .heldElsewhere) { page in
            #expect(!page.page.isEditable, "precondition: read-only")
            try page.select("The tide was already turning.")
            #expect(page.formatting.selection(in: .body) == nil, "precondition: the formatting bar is dimmed")
            #expect(page.readAloud.control == .read)
            page.readAloud.press()
            #expect(page.readAloud.control == .stop)
            #expect(try page.speech.requests.map(\.text) == ["The tide was already turning."])
        }
    }

    /// Only the page is read: a selection in the notes leaves ▶ dimmed.
    @Test func aSelectionInTheNotesIsNotRead() async throws {
        var withNotes = ferry
        withNotes.notes = [[Run("Check the tides.")]]
        try await withPage([withNotes]) { page in
            page.focusPage(at: 0)
            let notes = try await page.showNotes()
            page.focusNotes(notes, at: 0)
            notes.setSelectedRange(NSRange(location: 0, length: 5))
            #expect(notes.selectedRange().length == 5, "precondition: the notes have a selection")
            #expect(page.readAloud.control == .unavailable)
        }
    }

    @Test func anEditToThePageStopsTheReading() async throws {
        try await withPage([ferry]) { page in
            page.focusPage(at: 0)
            try page.startReading("The tide was already turning.")
            page.page.insertText("X", replacementRange: NSRange(location: 0, length: 0))
            #expect(page.readAloud.state == .idle)
            #expect(page.page.spoken.isEmpty)
            #expect(try page.speech.stops == 1)
        }
    }

    /// Deleting or typing over the sentence being read, at the very end of the text or in the
    /// middle, through the text view as a key would: the reading stops while the storage still
    /// processes the edit, with the selection not yet moved off the deleted text.
    @Test(arguments: [EditOverReading.deleteAtTheEnd, .typeOverAtTheEnd, .deleteInTheMiddle])
    func editingTheSentenceBeingReadStopsTheReading(_ edit: EditOverReading) async throws {
        try await withPage([ferry]) { page in
            page.focusPage(at: 0)
            let sentence = edit.sentence
            try #require(
                (edit == .deleteInTheMiddle) != page.storage.string.hasSuffix(sentence),
                "precondition: the sentence ends the text or doesn't, as the case says")
            try page.startReading(sentence)
            let utterance = try #require(try page.speech.requests.last?.text) as NSString
            try page.speech.report(.willSpeak(NSRange(location: 0, length: min(4, utterance.length))))
            try #require(page.page.spoken == [page.range(of: sentence)], "precondition: highlighted")

            await onTheRunLoop {
                switch edit {
                case .deleteAtTheEnd, .deleteInTheMiddle: page.page.deleteBackward(nil)
                case .typeOverAtTheEnd: page.page.insertText("X", replacementRange: page.page.selectedRange())
                }
            }
            #expect(!page.storage.string.contains(sentence), "the edit went through")
            #expect(page.readAloud.state == .idle)
            #expect(page.page.spoken.isEmpty)
            await afterTheMainQueue()
            #expect(page.renderedBackgrounds(in: NSRange(location: 0, length: page.storage.length)).isEmpty)
            #expect(page.pageMirrorsModel)
        }
    }

    @Test func openingAnotherSceneStopsTheReading() async throws {
        try await withPage([ferry, station]) { page in
            page.focusPage(at: 0)
            try page.startReading("The tide was already turning.")
            page.book.select(page.book.book.scenes[1].id)
            await eventually { page.storage.string.hasPrefix("The train") }
            #expect(page.readAloud.state == .idle)
        }
    }

    @Test func openingASheetStopsTheReading() async throws {
        try await withPage([ferry]) { page in
            page.focusPage(at: 0)
            try page.startReading("The tide was already turning.")
            page.modes.mode = .scenes
            await eventually { page.readAloud.state == .idle }
            #expect(try page.speech.stops == 1)
        }
    }

    /// A stopped reading's last events, which a synthesizer reports after it stops, never touch
    /// the next one.
    @Test func aStoppedReadingsLateEventsAreIgnored() async throws {
        try await withPage([ferry]) { page in
            page.focusPage(at: 0)
            try page.startReading("Mara watched")
            page.readAloud.press()
            try page.startReading("Dawn came late.")
            let speech = try page.speech
            speech.report(.willSpeak(NSRange(location: 0, length: 4)), aboutRequest: 0)
            speech.report(.ended, aboutRequest: 0)
            #expect(page.readAloud.control == .stop, "still reading the second")
            #expect(page.page.spoken.isEmpty)
            speech.report(.willSpeak(NSRange(location: 0, length: 4)))
            #expect(page.page.spoken == [page.range(of: "Dawn came late.")])
        }
    }

    /// A highlighted word inside the selection shows the selection's colour (ADR 0034), but inside
    /// the sentence being read it shows the sentence's, so the sentence reads as one band.
    @Test func theSentenceIsOneBandOverHighlightedWords() async throws {
        let lit = scene(
            "Lit", [[Run("Mara watched the "), Run("harbor", highlight: .green), Run(" lights. Dawn came.")]])
        try await withPage([lit]) { page in
            page.focusPage(at: 0)
            let harbor = page.range(of: "harbor")
            try page.startReading("Mara watched the harbor lights. Dawn")
            #expect(
                page.renderedBackgrounds(in: harbor) == [harbor: page.page.selectionColor],
                "precondition: the selection's colour over the highlight")

            let speech = try page.speech
            let utterance = try #require(speech.requests.last?.text) as NSString
            speech.report(.willSpeak(utterance.range(of: "harbor")))
            let sentence = page.range(of: "Mara watched the harbor lights.")
            #expect(page.renderedBackgrounds(in: sentence) == [sentence: SceneTextView.spokenSentenceColor])

            speech.report(.ended)
            #expect(page.renderedBackgrounds(in: sentence) == [harbor: page.page.selectionColor])
        }
    }

    /// When the window goes (the book closes, or is read again), so does the reading.
    @Test func theWindowGoingStopsTheReading() async throws {
        try await withPage([ferry]) { page in
            page.focusPage(at: 0)
            try page.startReading("The tide was already turning.")
            page.window.contentViewController = nil
            await eventually { page.readAloud.state == .idle }
            #expect(try page.speech.stops == 1)
        }
    }

    /// A new window's page takes over: the old page's reading stops and its selection no longer
    /// counts.
    @Test func attachingAnotherPageStopsTheReading() async throws {
        try await withPage([ferry]) { page in
            page.focusPage(at: 0)
            try page.startReading("The tide was already turning.")
            let next = ManuscriptTextView.page(editability: { .readOnly })
            page.readAloud.attach(next, of: page.book)
            #expect(page.readAloud.state == .idle)
            #expect(page.page.spoken.isEmpty)
            #expect(page.readAloud.control == .unavailable, "the new page has nothing selected")
            #expect(try page.speech.stops == 1)
        }
    }
}

enum EditOverReading: CaseIterable, Sendable {
    case deleteAtTheEnd, typeOverAtTheEnd, deleteInTheMiddle

    var sentence: String {
        switch self {
        case .deleteAtTheEnd, .typeOverAtTheEnd: "Dawn came late."
        case .deleteInTheMiddle: "The tide was already turning."
        }
    }
}

extension PageHarness {
    /// The page's rendering-attribute background colours within `range`, by the ranges they cover,
    /// touching runs of one colour joined.
    func renderedBackgrounds(in range: NSRange) -> [NSRange: NSColor] {
        guard let layout = page.textLayoutManager, let content = layout.textContentManager else { return [:] }
        let start = content.documentRange.location
        var runs: [(range: NSRange, color: NSColor)] = []
        layout.enumerateRenderingAttributes(from: start, reverse: false) { _, attributes, textRange in
            let offsets = NSRange(
                location: content.offset(from: start, to: textRange.location),
                length: content.offset(from: textRange.location, to: textRange.endLocation))
            if let color = attributes[.backgroundColor] as? NSColor, let inside = offsets.intersection(range),
                inside.length > 0
            {
                runs.append((inside, color))
            }
            return true
        }
        var joined: [(range: NSRange, color: NSColor)] = []
        for run in runs.sorted(by: { $0.range.location < $1.range.location }) {
            if let last = joined.last, last.color == run.color, NSMaxRange(last.range) == run.range.location {
                joined[joined.count - 1].range.length += run.range.length
            } else {
                joined.append(run)
            }
        }
        return Dictionary(uniqueKeysWithValues: joined.map { ($0.range, $0.color) })
    }
}

/// Cmd+Shift+R as a keyboard delivers it ("R" ignoring modifiers), once SwiftUI has caught up
/// with the button's state, which it does on a later turn.
@MainActor
private func pressReadAloud(in page: PageHarness) async throws {
    await afterTheMainQueue()
    page.window.contentView?.layoutSubtreeIfNeeded()
    await afterTheMainQueue()
    try press(.readAloud, in: page.window)
}

extension OneAtATime {
    @MainActor
    @Suite(.timeLimit(.minutes(2)))
    struct ReadAloudKeyTests {
        /// Cmd+Shift+R is ▶, and ■ while reading (PLAN §11).
        @Test func commandShiftRReadsAndStops() async throws {
            try await withPage([ferry], in: KeyWindow.self) { page in
                page.focusPage(at: 0)
                try page.select("The tide was already turning.")
                try await pressReadAloud(in: page)
                #expect(page.readAloud.control == .stop)
                #expect(try page.speech.requests.map(\.text) == ["The tide was already turning."])
                try await pressReadAloud(in: page)
                #expect(page.readAloud.control == .read)
                #expect(page.pageMirrorsModel, "the key typed nothing")

                page.modes.mode = .scenes
                try await pressReadAloud(in: page)
                #expect(page.readAloud.control == .read, "under a sheet, the key reads nothing")
                #expect(try page.speech.requests.count == 1)
            }
        }

        /// After the open scene is deleted no scene is open, though the page keeps the deleted
        /// scene's text and selection: ▶ is dimmed and the key reads nothing.
        @Test func withNoSceneOpenTheKeyReadsNothing() async throws {
            let cut = scene("The brother", [[Run("He never wrote back. Nobody asked why.")]])
            let prompts = AnsweringPrompts([DeleteChoice.delete])
            let books = BookController(role: .testHost, prompts: prompts)
            try await withPage([ferry], boneyard: [cut], books: books, in: KeyWindow.self) { page in
                page.book.select(cut.id)
                await eventually { page.storage.string.hasPrefix("He never") }
                page.focusPage(at: 0)
                try page.select("Nobody asked why.")
                try await pressReadAloud(in: page)
                try #require(page.readAloud.control == .stop, "precondition: the key reads the open scene")
                page.readAloud.stop()

                page.modes.mode = .scenes
                let modes = page.modes
                let mode = Binding(get: { modes.mode }, set: { modes.mode = $0 })
                let actions = ScenesActions(
                    book: page.book, store: page.store, preferences: page.preferences, model: page.scenes,
                    tags: TagActions(book: page.book, page: page.page, search: page.search, mode: mode),
                    mode: mode)
                await actions.deletePermanently(cut.id)
                try #require(page.book.openScene == nil, "precondition: no scene is open")
                page.modes.mode = .page
                #expect(page.page.selectedRange().length > 0, "the page keeps its last selection")
                #expect(page.readAloud.control == .unavailable)
                try await pressReadAloud(in: page)
                #expect(try page.speech.requests.count == 1, "the key read nothing")
            }
        }

        /// The button's shortcut is its own: no menu item has it, spelled either way.
        @Test func noMenuItemHasCommandShiftR() {
            @MainActor func items(_ menu: NSMenu?) -> [NSMenuItem] {
                (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
            }
            let all = items(NSApp.mainMenu)
            #expect(!all.isEmpty, "precondition: the app's menus are installed")
            let sharing = all.filter { item in
                var modifiers = item.keyEquivalentModifierMask.intersection([
                    .command, .option, .shift, .control,
                ])
                if item.keyEquivalent == "R" { modifiers.insert(.shift) }
                return item.keyEquivalent.lowercased() == "r" && modifiers == [.command, .shift]
            }
            #expect(sharing.map(\.title) == [])
        }
    }
}
