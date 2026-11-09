import AppKit

/// A paragraph laid out as TextKit does, except for the end line after a final empty paragraph
/// (Return twice at the end, #102), which is placed as the empty paragraph a letter typed there
/// would start: a copy of the empty line above it, its spacing before included.
///
/// TextKit lays that line out inside the last paragraph's fragment, so it ignores spacing before,
/// the only spacing an empty line takes without growing its caret (ADR 0034); it puts the line
/// straight under the empty one, and how tall it makes it depends on where the caret is.
public class EndLineFragment: NSTextLayoutFragment, @unchecked Sendable {
    override public var textLineFragments: [NSTextLineFragment] {
        let lines = super.textLineFragments
        guard let end = endLine(of: lines), let laidOut = lines.last else { return lines }
        return lines.dropLast() + [
            PlacedLineFragment(laidOut, at: end.bounds, glyphOrigin: end.glyphOrigin)
        ]
    }

    /// Down to the end line as placed.
    override public var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        let lines = super.textLineFragments
        guard let end = endLine(of: lines), let laidOut = lines.last else { return frame }
        frame.size.height += end.bounds.maxY - laidOut.typographicBounds.maxY
        return frame
    }

    /// Where the end line goes, if `lines` are a final empty paragraph's line, with spacing
    /// before it, and the end line.
    private func endLine(of lines: [NSTextLineFragment]) -> (bounds: CGRect, glyphOrigin: CGPoint)? {
        guard lines.count == 2, let empty = lines.first, let laidOut = lines.last,
            laidOut.characterRange.length == 0, empty.characterRange.length > 0,
            NSMaxRange(laidOut.characterRange) <= laidOut.attributedString.length,
            NSMaxRange(empty.characterRange) <= empty.attributedString.length,
            state == .layoutAvailable,
            // Only the last paragraph ends in the end line, but TextKit can still give one to a
            // paragraph that text has just been typed after.
            let document = textLayoutManager?.documentRange,
            rangeInElement.endLocation.compare(document.endLocation) == .orderedSame,
            // The lines' own text: the paragraph's can be out of step with them during an edit,
            // and reading it then can throw.
            ParagraphContent(
                ofParagraphAt: empty.characterRange.location, in: empty.attributedString.string as NSString)
                == .empty,
            let style = empty.attributedString.attribute(
                .paragraphStyle, at: empty.characterRange.location, effectiveRange: nil) as? NSParagraphStyle,
            style.paragraphSpacingBefore > 0
        else { return nil }
        var bounds = empty.typographicBounds
        bounds.origin.y = bounds.maxY + style.paragraphSpacingBefore
        return (bounds, empty.glyphOrigin)
    }
}

/// A line with no glyphs, placed where it's given.
private final class PlacedLineFragment: NSTextLineFragment {
    private let bounds: CGRect
    private let origin: CGPoint

    init(_ line: NSTextLineFragment, at bounds: CGRect, glyphOrigin: CGPoint) {
        self.bounds = bounds
        origin = glyphOrigin
        super.init(attributedString: line.attributedString, range: line.characterRange)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var typographicBounds: CGRect {
        bounds
    }

    override var glyphOrigin: CGPoint {
        origin
    }
}
