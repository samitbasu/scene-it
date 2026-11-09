import CoreGraphics

/// Where the connectors leaving one line run (PLAN §10.1): each drops from the end of its
/// underline to a lane of its own in the gap below the line, under every underline there, and
/// runs along it to the gutter, so no two share a height and none runs along an underline.
///
/// The comments on a line are taken right to left: the rightmost gets the top lane and the top
/// box in the column, the leftmost the bottom lane and the bottom box. Then no connector's drop
/// crosses another's lane, and no two cross on their way from the gutter to their boxes.
public enum ConnectorLanes {
    /// The space between two lanes, when the gap has room for it.
    public static let pitch = PaperLength(3)

    /// `count` lanes, top to bottom, inside the band from `top` (below the line's deepest
    /// underline) to `bottom` (above the next line's letters): `pitch` apart, starting half a
    /// pitch down, or closer together if that's what fits. All are distinct while `count` is
    /// positive and the band is; an empty band puts them all at its top.
    public static func lanes(_ count: Int, from top: PaperLength, to bottom: PaperLength) -> [PaperLength] {
        guard count > 0 else { return [] }
        let room = CGFloat(bottom - top)
        let step = min(CGFloat(pitch), room / CGFloat(count))
        return (0..<count).map { top + PaperLength(step * (CGFloat($0) + 0.5)) }
    }

    /// The order the comments starting on one line go into the column: right to left by where
    /// their connectors leave the text, given as offsets in the text.
    public static func columnOrder<T>(_ comments: [T], leavingAt end: (T) -> Int) -> [T] {
        comments.enumerated().sorted { (-end($0.element), $0.offset) < (-end($1.element), $1.offset) }.map(
            \.element)
    }
}
