import AVFoundation
import SceneItCore

/// What to say, and how.
struct SpeechRequest: Equatable {
    let text: String
    /// `nil` for the system's voice.
    let voice: VoiceIdentifier?
    let rate: SpeechRate
}

/// What a synthesizer reports about the text it was asked to speak.
enum SpeechEvent: Equatable {
    /// It's about to speak this range of the text (UTF-16 offsets), usually a word.
    case willSpeak(NSRange)
    /// It finished the text, or was stopped.
    case ended
}

/// A speech synthesizer: `AVSpeechSynthesizer` in the app; in the test host and previews a
/// recorder that never makes a sound.
protocol SpeechSynthesizing: AnyObject {
    /// Speaks `request`, reporting each event to `events` on the main actor. Speaking stops
    /// whatever was being spoken.
    func speak(_ request: SpeechRequest, events: @escaping (SpeechEvent) -> Void)
    func stop()
}

/// `AVSpeechSynthesizer`, on this Mac (ADR 0044).
final class SystemSpeech: NSObject, SpeechSynthesizing {
    private let synthesizer = AVSpeechSynthesizer()
    /// Each utterance not yet ended, and who hears of it. Holding the utterance keeps its
    /// identifier from being reused by a new one before its last event arrives.
    private var listeners: [ObjectIdentifier: (utterance: AVSpeechUtterance, events: (SpeechEvent) -> Void)] =
        [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ request: SpeechRequest, events: @escaping (SpeechEvent) -> Void) {
        stop()
        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = Self.voice(request.voice)
        utterance.rate = Float(request.rate)
        listeners[ObjectIdentifier(utterance)] = (utterance, events)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// A stored voice this Mac doesn't have is the system's.
    private static func voice(_ identifier: VoiceIdentifier?) -> AVSpeechSynthesisVoice? {
        identifier.flatMap { AVSpeechSynthesisVoice(identifier: $0.rawValue) }
            ?? AVSpeechSynthesisVoice(language: nil)
    }

    private func report(_ event: SpeechEvent, about utterance: ObjectIdentifier) {
        listeners[utterance]?.events(event)
        if event == .ended { listeners[utterance] = nil }
    }

    /// The synthesizer may call its delegate on a queue of its own.
    private nonisolated func deliver(_ event: SpeechEvent, about utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.report(event, about: id) }
        }
    }
}

extension SystemSpeech: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        deliver(.willSpeak(characterRange), about: utterance)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        deliver(.ended, about: utterance)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        deliver(.ended, about: utterance)
    }
}

/// The test host's and previews' synthesizer: it keeps what it was asked to say, and reports
/// only the events a test plays through `report`.
final class RecordedSpeech: SpeechSynthesizing {
    private(set) var requests: [SpeechRequest] = []
    private(set) var stops = 0
    private var listeners: [(SpeechEvent) -> Void] = []

    func speak(_ request: SpeechRequest, events: @escaping (SpeechEvent) -> Void) {
        requests.append(request)
        listeners.append(events)
    }

    func stop() {
        stops += 1
    }

    /// Plays `event` as the synthesizer would report it about `requests[index]`, by default the
    /// last.
    func report(_ event: SpeechEvent, aboutRequest index: Int? = nil) {
        guard let listen = index.map({ listeners[$0] }) ?? listeners.last else { return }
        listen(event)
    }
}
