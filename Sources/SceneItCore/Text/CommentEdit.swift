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
    /// What a comment made on `selection` covers (PLAN §8.1, ADR 0037): the selected ranges
    /// holding more than line breaks, which carry no comment (book format §4.2). Empty when that's
    /// nothing, as with no selection.
    public func commentRanges(selecting selection: [NSRange]) -> [NSRange] {
        let string = string as NSString
        return selection.filter { range in
            (range.location..<range.upperBound).contains { !string.isLineBreak(at: $0) }
        }
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
