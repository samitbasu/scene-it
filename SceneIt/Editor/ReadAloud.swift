import AppKit
import SceneItCore

/// Read aloud (PLAN §10.3): the page's selection spoken in the voice and at the rate the
/// preferences hold, the sentence being read highlighted on the page for display only. It reads
/// the page alone, never the notes or a comment, whether or not the page can be edited, so a
/// read-only book can be read too. Reading stops when the page's text changes (an edit, or
/// another scene shown), when a sheet opens and when the window goes.
///
/// One per process, as there is one main window (ADR 0038); each window's page attaches itself.
@Observable
final class ReadAloud: NSObject {
    private(set) var state = State.idle
    private(set) var pageSelection = PageSelection.empty
    @ObservationIgnored let preferences: AppPreferences
    @ObservationIgnored let speech: any SpeechSynthesizing
    @ObservationIgnored private weak var page: ManuscriptTextView?
    @ObservationIgnored private var utterances = 0

    enum State: Equatable {
        case idle
        case reading(Reading)
    }

    struct Reading: Equatable {
        /// Which `speak` this is, so a stopped one's late events are ignored.
        let utterance: Int
        let text: SpokenText
        /// The sentence being read, as ranges of the page's text.
        var sentence: [NSRange]
    }

    enum PageSelection {
        case empty, text
    }

    /// What the bar's button does: ▶ reads, ■ stops.
    enum Control {
        case unavailable, read, stop
    }

    var control: Control {
        switch state {
        case .reading: .stop
        case .idle: pageSelection == .text ? .read : .unavailable
        }
    }

    init(preferences: AppPreferences, speech: any SpeechSynthesizing) {
        self.preferences = preferences
        self.speech = speech
    }

    /// Reads `page`, the page of `book`'s window, from now on.
    func attach(_ page: ManuscriptTextView, of book: AppOpenBook) {
        stop()
        NotificationCenter.default.removeObserver(self)
        self.page = page
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(selectionDidChange), name: NSTextView.didChangeSelectionNotification,
            object: page)
        center.addObserver(
            self, selector: #selector(textDidProcessEditing),
            name: NSTextStorage.didProcessEditingNotification,
            object: page.textStorage)
        center.addObserver(
            self, selector: #selector(sceneWillSwitch), name: .openBookWillSwitchScene, object: book)
        selectionDidChange()
    }

    func press() {
        switch control {
        case .read: start()
        case .stop: stop()
        case .unavailable: break
        }
    }

    func stop() {
        guard case .reading = state else { return }
        state = .idle
        page?.spoken = []
        speech.stop()
    }

    private func start() {
        guard let page,
            let text = SpokenText(
                selecting: page.selectedRanges.map(\.rangeValue), in: page.string as NSString)
        else { return }
        utterances += 1
        let utterance = utterances
        state = .reading(Reading(utterance: utterance, text: text, sentence: []))
        let request = SpeechRequest(
            text: text.utterance, voice: preferences.readAloudVoice, rate: preferences.readAloudRate)
        speech.speak(request) { [weak self] event in
            self?.heard(event, about: utterance)
        }
    }

    private func heard(_ event: SpeechEvent, about utterance: Int) {
        guard case .reading(var reading) = state, reading.utterance == utterance else { return }
        switch event {
        case .willSpeak(let range):
            reading.sentence = reading.text.sourceRanges(ofSentenceAround: range)
            state = .reading(reading)
            page?.spoken = reading.sentence
        case .ended:
            state = .idle
            page?.spoken = []
        }
    }

    @objc private func selectionDidChange() {
        let selected: PageSelection =
            page?.selectedRanges.contains(where: { $0.rangeValue.length > 0 }) == true ? .text : .empty
        if pageSelection != selected { pageSelection = selected }
    }

    @objc private func textDidProcessEditing(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
            storage.editedMask.contains(.editedCharacters)
        else { return }
        stop()
    }

    @objc private func sceneWillSwitch(_ notification: Notification) {
        stop()
    }
}
