import AppKit

/// A change to the comments on text, leaving its format alone (PLAN §8.1).
public enum CommentEdit: Hashable, Sendable {
    case add(CommentID)
    case remove(CommentID)

    /// `attributes` with the edit applied, as the codec renders them in `role`.
    public func applied(to attributes: [NSAttributedString.Key: Any], in role: ParagraphRole)
        -> [NSAttributedString.Key: Any]
    {
        var format = RunFormat(attributes)
        switch self {
        case .add(let id): format.comments.insert(id)
        case .remove(let id): format.comments.remove(id)
        }
        return format.attributes(in: role)
    }
}

extension NSAttributedString {
    /// What a comment made on `selection` covers (PLAN §8.1): the selected ranges holding more
    /// than line breaks, which carry no comment (book format §4.2); or, with nothing selected,
    /// the word at the caret. Empty when that's nothing.
    public func commentRanges(selecting selection: [NSRange]) -> [NSRange] {
        let selected = selection.filter { $0.length > 0 }
        guard !selected.isEmpty else {
            return selection.first.flatMap { word(at: $0.location) }.map { [$0] } ?? []
        }
        let string = string as NSString
        return selected.filter { range in
            (range.location..<range.upperBound).contains { !string.isLineBreak(at: $0) }
        }
    }

    /// The word the caret at `caret` is in or just after, as a double click selects it.
    private func word(at caret: Int) -> NSRange? {
        let string = string as NSString
        for index in [caret, caret - 1] where (0..<length).contains(index) {
            let word = doubleClick(at: index)
            if string.substring(with: word).unicodeScalars.contains(
                where: CharacterSet.alphanumerics.contains)
            {
                return word
            }
        }
        return nil
    }

    /// The stretches of the text `comment` covers, in order.
    public func ranges(commentedBy comment: CommentID) -> [NSRange] {
        var ranges: [NSRange] = []
        enumerateAttribute(.comments, in: NSRange(location: 0, length: length)) { value, range, _ in
            guard CommentPalette.ids(in: value).contains(comment) else { return }
            if let last = ranges.last, last.upperBound == range.location {
                ranges[ranges.count - 1] = last.union(range)
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }
}
