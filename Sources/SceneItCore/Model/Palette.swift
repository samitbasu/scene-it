/// PLAN §6.2's seven palette names, as stored in `book.json`. A comment can be any of them.
public enum PaletteColor: String, StrictStringEnum {
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

/// A run's text color. There is no `black`: a run without a color is black
/// (decision 0013).
public enum TextColor: String, StrictStringEnum {
    case purple, red, blue, green, gray, pink

    /// `nil` for black, which a run expresses by having no color.
    public init?(_ palette: PaletteColor) {
        self.init(rawValue: palette.rawValue)
    }
}

public enum HighlightColor: String, StrictStringEnum {
    case purple, red, blue, green, gray, pink
}
