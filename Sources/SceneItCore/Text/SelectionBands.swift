import AppKit

/// Where the selection is drawn in the editors (ADR 0034): one band per line, as tall as a line of
/// text and level with its letters, the height the cursor is. TextKit's own selection segments
/// reach up over the double spacing above each line after the first, which joins the lines into
/// one block.
public enum SelectionBands {
    /// Where a band ends when the selection goes on past the end of its line.
    public enum LineEnd: Sendable {
        /// At the line's trailing edge, as the system's selection does.
        case trailingEdge
        /// At the line's last selected letter.
        case lastLetter
    }

    /// The bands of `ranges`, in the text container's coordinates.
    public static func bands(
        of ranges: [NSTextRange], in layout: NSTextLayoutManager, lineEnd: LineEnd
    ) -> [CGRect] {
        let type: NSTextLayoutManager.SegmentType =
            switch lineEnd {
            case .trailingEdge: .selection
            case .lastLetter: .standard
            }
        var bands: [CGRect] = []
        for range in ranges where !range.isEmpty {
            layout.enumerateTextSegments(in: range, type: type, options: [.rangeNotRequired]) {
                _, frame, _, _ in
                bands.append(band(in: frame))
                return true
            }
        }
        return bands
    }

    /// The band of one segment: its bottom line's height, since the spacing is above a line's letters
    /// within a segment; at least a space wide, as an empty paragraph's break shows.
    static func band(in segment: CGRect) -> CGRect {
        let height = min(segment.height, ParagraphRole.textLineHeight)
        return CGRect(
            x: segment.minX, y: segment.maxY - height, width: max(segment.width, breakWidth), height: height)
    }

    /// How wide a selected paragraph break shows when nothing else on its line is selected.
    static let breakWidth: CGFloat = (" " as NSString).size(withAttributes: [
        .font: ParagraphRole.body.font([])
    ]).width
}
