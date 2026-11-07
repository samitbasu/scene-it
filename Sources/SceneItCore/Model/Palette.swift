/// PLAN §6.2's seven palette names, as written in `book.md`. A comment can be any of them.
public enum PaletteColor: String, CaseIterable, Hashable, Sendable {
    case black, purple, red, blue, green, gray, pink

    /// `.black` for `nil`, the inverse of `TextColor.init?(_:)`.
    public init(_ color: TextColor?) {
        switch color {
        case nil: self = .black
        case .purple?: self = .purple
        case .red?: self = .red
        case .blue?: self = .blue
        case .green?: self = .green
        case .gray?: self = .gray
        case .pink?: self = .pink
        }
    }
}

extension PaletteColor {
    /// The color `name` means, in any ASCII case; `grey` is `gray`. `book.md` (§4.4) and the
    /// comments panel's search (PLAN §8.1) both read names through this.
    public init?(named name: some Sequence<UInt8>) {
        let lowered = String(decoding: Lexical.lowercased(name), as: UTF8.self)
        self.init(rawValue: lowered == "grey" ? "gray" : lowered)
    }

    public init?(named name: String) {
        self.init(named: name.utf8)
    }
}

/// A run's text color. There is no `black`: a run without a color is black
/// (decision 0013).
public enum TextColor: String, CaseIterable, Hashable, Sendable {
    case purple, red, blue, green, gray, pink

    /// `nil` for black, which a run expresses by having no color.
    public init?(_ palette: PaletteColor) {
        self.init(rawValue: palette.rawValue)
    }
}

public enum HighlightColor: String, CaseIterable, Hashable, Sendable {
    case purple, red, blue, green, gray, pink

    /// A highlight palette's choices: `nil` ("None") first, then the colors.
    public static let choices: [HighlightColor?] = [nil] + allCases
}

extension PaletteColor {
    public init(_ highlight: HighlightColor) {
        self.init(TextColor(rawValue: highlight.rawValue))
    }
}
