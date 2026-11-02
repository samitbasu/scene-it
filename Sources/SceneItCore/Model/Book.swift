/// The whole of `book.json` (PLAN §5.2).
///
/// `format` isn't stored: this version reads and writes only `BookFormat.current`, and a
/// file in any other format is refused before the rest of it is interpreted.
public struct Book: Hashable, Sendable {
    public var title: String
    public var settings: Settings
    /// Story order.
    public var scenes: [Scene]
    /// Cut scenes, most recently cut first.
    public var boneyard: [Scene]

    public init(
        title: String,
        settings: Settings = Settings(),
        scenes: [Scene] = [],
        boneyard: [Scene] = []
    ) {
        self.title = title
        self.settings = settings
        self.scenes = scenes
        self.boneyard = boneyard
    }
}

public enum BookFormat {
    public static let current = 1
}

extension Book: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case format, title, settings, boneyard, scenes
    }

    public init(from decoder: any Decoder) throws {
        let lenient = try decoder.container(keyedBy: CodingKeys.self)
        let format = try lenient.decode(Int.self, forKey: .format)
        guard format == BookFormat.current else {
            throw lenient.corrupted(
                .format, "format \(format) is not supported; this version reads format \(BookFormat.current)")
        }
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        settings = try container.decode(Settings.self, forKey: .settings)
        scenes = try container.decode([Scene].self, forKey: .scenes)
        boneyard = try container.decode([Scene].self, forKey: .boneyard)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(BookFormat.current, forKey: .format)
        try container.encode(title, forKey: .title)
        try container.encode(settings, forKey: .settings)
        try container.encode(boneyard, forKey: .boneyard)
        try container.encode(scenes, forKey: .scenes)
    }
}
