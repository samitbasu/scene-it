public enum RightPanelTab: String, StrictStringEnum {
    case comments, notes, tags
}

public enum ScenesView: String, StrictStringEnum {
    case cards, lightTable
}

/// `rightPanelOpen` in `book.json`.
public enum PanelVisibility: Hashable, Sendable, Codable {
    case open, closed

    public init(from decoder: any Decoder) throws {
        self = try decoder.singleValueContainer().decode(Bool.self) ? .open : .closed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self == .open)
    }
}

public struct Settings: Hashable, Sendable, Encodable {
    public var zoom: Zoom
    /// An `AVSpeechSynthesisVoice` identifier; `nil` means the system default voice.
    public var voice: String?
    public var rate: SpeechRate
    public var rightPanel: RightPanelTab
    public var rightPanelOpen: PanelVisibility
    public var scenesView: ScenesView

    public init(
        zoom: Zoom = Zoom(clamping: ZoomBounds.fallback),
        voice: String? = nil,
        rate: SpeechRate = SpeechRate(clamping: SpeechRateBounds.fallback),
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

extension Settings: Decodable {
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
