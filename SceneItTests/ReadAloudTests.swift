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
                await eventually { page.readAloud.control == .read }
                // SwiftUI enables the button on a later turn.
                await afterTheMainQueue()
                page.window.contentView?.layoutSubtreeIfNeeded()
                await afterTheMainQueue()
                try press(.readAloud, in: page.window)
                #expect(page.readAloud.control == .stop)
                #expect(try page.speech.requests.map(\.text) == ["The tide was already turning."])
                try press(.readAloud, in: page.window)
                #expect(page.readAloud.control == .read)
                #expect(page.pageMirrorsModel, "the key typed nothing")

                page.modes.mode = .scenes
                await afterTheMainQueue()
                page.window.contentView?.layoutSubtreeIfNeeded()
                await afterTheMainQueue()
                try press(.readAloud, in: page.window)
                #expect(page.readAloud.control == .read, "under a sheet, the key reads nothing")
                #expect(try page.speech.requests.count == 1)
            }
        }

        /// The button's shortcut is its own: no menu item has it.
        @Test func noMenuItemHasCommandShiftR() {
            @MainActor func items(_ menu: NSMenu?) -> [NSMenuItem] {
                (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
            }
            let modifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
            let all = items(NSApp.mainMenu)
            #expect(!all.isEmpty, "precondition: the app's menus are installed")
            let sharing = all.filter {
                $0.keyEquivalent.lowercased() == "r"
                    && $0.keyEquivalentModifierMask.intersection(modifiers) == [.command, .shift]
            }
            #expect(sharing.map(\.title) == [])
        }
    }
}
