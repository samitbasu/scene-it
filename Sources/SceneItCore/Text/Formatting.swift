import AppKit

/// One formatting action (PLAN §6.2, §11). The control bar, the Format menu and the shortcuts
/// all perform these, so they can't disagree about what a command does.
public enum FormattingCommand: Hashable, Sendable {
    /// On for the whole selection, or off if the whole selection already has it.
    case toggle(TextStyle)
    /// Black removes the color (decision 0013).
    case textColor(PaletteColor)
    /// `nil` ("None") removes the highlight.
    case highlight(HighlightColor?)

    /// What the command does to a selection formatted as `selection`: a mixed selection
    /// toggles on.
    public func edit(for selection: SelectionFormatting) -> FormatEdit {
        switch self {
        case .toggle(let style):
            selection.state(of: self) == .on ? .remove(style) : .add(style)
        case .textColor(let color):
            .color(TextColor(color))
        case .highlight(let highlight):
            .highlight(highlight)
        }
    }

    /// The palettes in PLAN §6.2's order, as the Format menu and the bar's palettes list them.
    public static let textColors: [FormattingCommand] = PaletteColor.allCases.map(Self.textColor)
    public static let highlights: [FormattingCommand] = HighlightColor.choices.map(Self.highlight)
}

/// How a formatting control shows the selection.
public enum ControlState: Hashable, Sendable {
    case off, on
    /// Some of the selection has it, some doesn't.
    case mixed
}

/// The formats a selection holds, for showing each control's state.
public struct SelectionFormatting: Hashable, Sendable {
    private let formats: Set<RunFormat>

    /// The formats of `runs`; an empty run counts, as the caret's typing format does.
    public init(_ runs: some Sequence<Run>) {
        formats = Set(runs.map(RunFormat.init))
    }

    /// The text in `ranges` of `text`. Line breaks carry no format the model keeps, so they
    /// don't count.
    @MainActor
    public init(selecting ranges: [NSRange], in text: NSAttributedString) {
        let string = text.string as NSString
        var formats = Set<RunFormat>()
        for range in ranges where range.length > 0 {
            text.enumerateAttributes(in: range) { attributes, run, _ in
                let isOnlyLineBreaks = string.substring(with: run).allSatisfy(\.isLineBreak)
                if !isOnlyLineBreaks { formats.insert(RunFormat(attributes)) }
            }
        }
        self.formats = formats
    }

    /// The caret's: what typing would produce.
    @MainActor
    public init(typing attributes: [NSAttributedString.Key: Any]) {
        formats = [RunFormat(attributes)]
    }

    /// `.on` when every format in the selection has what `command` applies; a selection
    /// with no text is `.off`.
    public func state(of command: FormattingCommand) -> ControlState {
        let matching = formats.count { format in
            switch command {
            case .toggle(let style): format.styles.contains(style)
            case .textColor(let color): format.color == TextColor(color)
            case .highlight(let highlight): format.highlight == highlight
            }
        }
        switch matching {
        case 0: return .off
        case formats.count: return .on
        default: return .mixed
        }
    }
}

/// A change to the format of text, leaving its other formatting and its comments alone.
public enum FormatEdit: Hashable, Sendable {
    case add(TextStyle)
    case remove(TextStyle)
    case color(TextColor?)
    case highlight(HighlightColor?)

    public func applied(to run: Run) -> Run {
        applied(to: RunFormat(run)).run(run.text)
    }

    /// `attributes` with the edit applied, as the codec renders them in `role`, `NSColor`s and
    /// palette names together.
    @MainActor
    public func applied(to attributes: [NSAttributedString.Key: Any], in role: ParagraphRole)
        -> [NSAttributedString.Key: Any]
    {
        applied(to: RunFormat(attributes)).attributes(in: role)
    }

    private func applied(to format: RunFormat) -> RunFormat {
        var format = format
        switch self {
        case .add(let style): format.styles.insert(style)
        case .remove(let style): format.styles.remove(style)
        case .color(let color): format.color = color
        case .highlight(let highlight): format.highlight = highlight
        }
        return format
    }
}
