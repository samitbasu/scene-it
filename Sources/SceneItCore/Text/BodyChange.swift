import AppKit

/// An edit to a body or notes, as a replacement of whole paragraphs: what an editor sends the
/// model for each change to its text, so a keystroke converts one paragraph rather than all.
///
/// Paragraphs are counted as the text's *lines*: an empty body is one empty line, which
/// is how `RunCodec` reads an empty page.
public struct BodyChange: Hashable, Sendable {
    /// The replaced lines of the body before the change.
    public let lines: Range<Int>
    /// What replaces them: at least one line.
    public let paragraphs: [Paragraph]

    public init(lines: Range<Int>, paragraphs: [Paragraph]) {
        self.lines = lines
        self.paragraphs = paragraphs
    }

    /// How many lines `body` has.
    public static func lineCount(of body: [Paragraph]) -> Int {
        max(body.count, 1)
    }

    /// `body` with the change made; `nil` if its lines aren't all in `body`.
    public func applied(to body: [Paragraph]) -> [Paragraph]? {
        var lines = body.isEmpty ? [Paragraph([])] : body
        guard self.lines.upperBound <= lines.count else { return nil }
        lines.replaceSubrange(self.lines, with: paragraphs)
        return lines == [[]] ? [] : lines
    }

    /// The paragraphs this change replaces in `body`; `nil` if they aren't all in it.
    public func replaced(in body: [Paragraph]) -> ArraySlice<Paragraph>? {
        let lines = body.isEmpty ? [Paragraph([])] : body
        guard self.lines.upperBound <= lines.count else { return nil }
        return lines[self.lines]
    }

    /// The same change with `transform` applied to the new paragraphs.
    public func mapParagraphs(_ transform: (Paragraph) -> Paragraph) -> BodyChange {
        BodyChange(lines: lines, paragraphs: paragraphs.map(transform))
    }
}

extension RunCodec {
    /// The change to a body that held `linesBefore` lines and now reads as `text`, given
    /// that every character outside `edited` (a range of `text`) is as it was: the lines
    /// `edited` touches, converted again. `nil` if `linesBefore` can't be right.
    public static func bodyChange(edited: NSRange, in text: NSAttributedString, linesBefore: Int)
        -> BodyChange?
    {
        let string = text.string as NSString
        guard edited.location >= 0, edited.upperBound <= string.length,
            let (region, before, linesAfter) = LineBreaks.scan(string, around: edited)
        else { return nil }
        let paragraphs = lines(from: text.attributedSubstring(from: NSRange(region)))
        let replaced = paragraphs.count - (linesAfter - linesBefore)
        guard replaced >= 0, before + replaced <= linesBefore else { return nil }
        return BodyChange(lines: before..<before + replaced, paragraphs: paragraphs)
    }

    /// The change that replaces all `linesBefore` lines of a body with `text`.
    public static func bodyChange(replacingAll linesBefore: Int, with text: NSAttributedString) -> BodyChange
    {
        BodyChange(lines: 0..<linesBefore, paragraphs: lines(from: text))
    }
}

/// UTF-16 text split into lines by the codec's rule: every `Character.isLineBreak` ends one,
/// and `\r\n` is a single break. Breaks are counted by a regular expression, so a keystroke
/// never walks a long scene character by character in Swift.
private enum LineBreaks {
    /// Every `Character.isLineBreak`, as UTF-16, with `\r\n` matched first.
    private static let breaks = try? NSRegularExpression(
        pattern: "\\r\\n|[\\n\\x{0B}\\x{0C}\\r\\x{85}\\x{2028}\\x{2029}]")

    /// The whole lines holding `range` (line breaks excluded), how many lines come before
    /// them, and how many lines the text has; `nil` only if the pattern didn't compile.
    static func scan(_ string: NSString, around range: NSRange) -> (
        region: Range<Int>, before: Int, lines: Int
    )? {
        guard let breaks else { return nil }
        let length = string.length
        func isBreak(_ index: Int) -> Bool {
            switch string.character(at: index) {
            case 0x0A...0x0D, 0x85, 0x2028, 0x2029: true
            default: false
            }
        }
        /// Whether `index` falls between the `\r` and `\n` of a `\r\n`.
        func isCRLF(at index: Int) -> Bool {
            index > 0 && index < length && string.character(at: index - 1) == 0x0D
                && string.character(at: index) == 0x0A
        }
        var start = range.location
        while start > 0, !isBreak(start - 1) || isCRLF(at: start) {
            start -= 1
        }
        var end = range.upperBound
        while end < length, !isBreak(end) || isCRLF(at: end) {
            end += 1
        }
        let text = string as String
        func count(_ range: Range<Int>) -> Int {
            breaks.numberOfMatches(in: text, range: NSRange(range))
        }
        let before = count(0..<start)
        return (start..<end, before, before + count(start..<end) + count(end..<length) + 1)
    }
}
