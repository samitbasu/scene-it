public enum ScenesView: String, StrictStringEnum {
    case cards, lightTable
}

public struct BookSettings: Hashable, Sendable, Encodable {
    public var zoom: Zoom
    /// An `AVSpeechSynthesisVoice` identifier; `nil` means the system default voice.
    public var voice: String?
    public var rate: SpeechRate
    public var rightPanel: RightPanelTab
    public var rightPanelOpen: PanelVisibility
    public var scenesView: ScenesView

    public init(
        zoom: Zoom = .standard,
        voice: String? = nil,
        rate: SpeechRate = .standard,
        rightPanel: RightPanelTab = .comments,
        rightPanelOpen: PanelVisibility = .open,
        scenesView: ScenesView = .cards
    ) {
        self.zoom = zoom
        self.voice = voice
        self.rate = rate
        self.rightPanel = rightPanel
        self.rightPanelOpen = rightPanelOpen
        self.scenesView = scenesView
    }
}

extension BookSettings: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case zoom, voice, rate, rightPanel, rightPanelOpen, scenesView
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        zoom = try container.decode(Zoom.self, forKey: .zoom)
        voice = try container.decodeUnlessAbsent(String.self, forKey: .voice)
        rate = try container.decode(SpeechRate.self, forKey: .rate)
        rightPanel = try container.decode(RightPanelTab.self, forKey: .rightPanel)
        rightPanelOpen = try container.decode(PanelVisibility.self, forKey: .rightPanelOpen)
        scenesView = try container.decode(ScenesView.self, forKey: .scenesView)
    }
}
