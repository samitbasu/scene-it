/// A read-aloud voice, as `AVSpeechSynthesisVoice.identifier` names it
/// ("com.apple.voice.premium.en-US.Zoe"). It may name a voice this Mac doesn't have.
public struct VoiceIdentifier: Hashable, Sendable {
    public let rawValue: String

    /// `nil` for the empty string, which names no voice.
    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}
