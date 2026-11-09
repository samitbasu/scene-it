import CoreGraphics
import Testing

@testable import SceneItCore

/// Each connector leaving a line runs to the gutter in a lane of its own, below the line's
/// underlines, and the line's comments go into the column right to left, so no connector shares a
/// height with another or crosses one.
struct ConnectorLanesTests {
    @Test func lanesArePitchApartInsideTheBand() {
        let lanes = ConnectorLanes.lanes(3, from: PaperLength(10), to: PaperLength(20))
        #expect(lanes == [PaperLength(11.5), PaperLength(14.5), PaperLength(17.5)])
    }

    @Test func aCrowdedBandBringsTheLanesCloserButKeepsThemApartAndInside() throws {
        let (top, bottom) = (PaperLength(10), PaperLength(14))
        try #require(
            CGFloat(bottom - top) < 8 * CGFloat(ConnectorLanes.pitch),
            "precondition: eight don't fit at the pitch")
        let lanes = ConnectorLanes.lanes(8, from: top, to: bottom)
        #expect(Set(lanes).count == 8, "every lane its own height")
        #expect(lanes == lanes.sorted())
        #expect(lanes.allSatisfy { $0 > top && $0 < bottom })
    }

    @Test func anEmptyBandPutsThemAtItsTop() {
        #expect(
            ConnectorLanes.lanes(2, from: PaperLength(10), to: PaperLength(8)) == [
                PaperLength(10), PaperLength(10),
            ])
        #expect(ConnectorLanes.lanes(0, from: PaperLength(0), to: PaperLength(8)).isEmpty)
    }

    @Test func theColumnTakesALinesCommentsRightToLeft() {
        let ends = [("a", 5), ("b", 20), ("c", 12), ("d", 20)]
        #expect(ConnectorLanes.columnOrder(ends) { $0.1 }.map(\.0) == ["b", "d", "c", "a"])
    }

    /// Comment k (column order) leaves the text at x_k, drops to lane y_k and runs right to the
    /// gutter, then to box k; boxes go down the column in order. With x falling and y rising
    /// along the order, no drop meets another's lane and no two meet on the way to their boxes.
    @Test(arguments: 1...6)
    func connectorsOnALineNeverCross(count: Int) {
        let ends = (0..<count).map { ($0 * 37) % 50 }
        let ordered = ConnectorLanes.columnOrder(Array(ends.enumerated())) { $0.element }
        let lanes = ConnectorLanes.lanes(count, from: PaperLength(20), to: PaperLength(31))
        for i in ordered.indices {
            for j in ordered.indices where j > i {
                let (left, right) = (ordered[j], ordered[i])
                #expect(left.element <= right.element, "later in the column is further left")
                #expect(lanes[j] > lanes[i], "and runs lower, so it passes under the other's drop")
            }
        }
    }
}
