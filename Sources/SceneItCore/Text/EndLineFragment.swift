import AppKit

/// A paragraph laid out as TextKit does, except for the end line after a final empty paragraph
/// (Return twice at the end, #102), which is placed as the empty paragraph a letter typed there
/// would start: a copy of the empty line above it, its spacing before included.
///
/// TextKit lays that line out inside the last paragraph's fragment, so it ignores spacing before,
/// the only spacing an empty line takes without growing its caret (ADR 0034); it puts the line
/// straight under the empty one, and how tall it makes it depends on where the caret is.
public class EndLineFragment: NSTextLayoutFragment, @unchecked Sendable {
    private let lock = NSLock()
    /// The end line as placed, the same object for as long as it stays where it is, as TextKit's
    /// own lines are.
    private var placed: PlacedLineFragment?

    override public var textLineFragments: [NSTextLineFragment] {
        let lines = super.textLineFragments
        guard let end = placedEndLine(of: lines) else { return lines }
        return lines.dropLast() + [end]
    }

    /// Down to the end line as placed.
    override public var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        let lines = super.textLineFragments
        guard let end = placedEndLine(of: lines), let laidOut = lines.last else { return frame }
        frame.size.height += end.typographicBounds.maxY - laidOut.typographicBounds.maxY
        return frame
    }

    /// The end line as placed, if `lines` are a final empty paragraph's line, with spacing before
    /// it, and the end line.
    private func placedEndLine(of lines: [NSTextLineFragment]) -> NSTextLineFragment? {
        // The lines' own text: the paragraph's can be out of step with them during an edit.
        // Only the last paragraph ends in the end line, but TextKit can still give one to a
        // paragraph that text has just been typed after.
        guard state == .layoutAvailable, let document = textLayoutManager?.documentRange,
            rangeInElement.endLocation.compare(document.endLocation) == .orderedSame,
            lines.count == 2, let empty = lines.first, let laidOut = lines.last,
            laidOut.characterRange.length == 0, empty.characterRange.length > 0,
            ParagraphContent(
                ofParagraphAt: empty.characterRange.location, in: empty.attributedString.string as NSString)
                == .empty,
            let style = empty.attributedString.attribute(
                .paragraphStyle, at: empty.characterRange.location, effectiveRange: nil) as? NSParagraphStyle,
            style.paragraphSpacingBefore > 0
        else { return nil }
        var bounds = empty.typographicBounds
        bounds.origin.y = bounds.maxY + style.paragraphSpacingBefore
        return lock.withLock {
            if let placed, placed.typographicBounds == bounds, placed.glyphOrigin == empty.glyphOrigin,
                placed.characterRange == laidOut.characterRange,
                placed.attributedString.isEqual(to: laidOut.attributedString)
            {
                return placed
            }
            let line = PlacedLineFragment(
                laidOut.attributedString, range: laidOut.characterRange, bounds: bounds,
                glyphOrigin: empty.glyphOrigin)
            placed = line
            return line
        }
    }
}

/// A line with no glyphs, placed where it's given.
private final class PlacedLineFragment: NSTextLineFragment, @unchecked Sendable {
    private let bounds: CGRect
    private let origin: CGPoint

    init(_ text: NSAttributedString, range: NSRange, bounds: CGRect, glyphOrigin: CGPoint) {
        self.bounds = bounds
        origin = glyphOrigin
        super.init(attributedString: text, range: range)
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
