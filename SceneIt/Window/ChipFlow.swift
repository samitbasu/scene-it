import SwiftUI

/// The gap between chips, and between their lines.
struct ChipSpacing {
    let points: CGFloat
}

/// Lays its views out left to right, wrapping to a new line where the next doesn't fit; the
/// last view (the text field) takes the rest of its line. A view wider than a whole line is
/// offered the line's width, so a chip with a long tag truncates rather than overflows. File a
/// Copy's tags and the Tags tab use it.
struct ChipFlow: Layout {
    let spacing: ChipSpacing

    /// How wide a line of chips may be.
    private struct LineWidth {
        let points: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let rows = arrange(subviews, within: LineWidth(points: width))
        let height = rows.reduce(0) { $0 + $1.height } + spacing.points * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, within: LineWidth(points: bounds.width)) {
            var x = bounds.minX
            for (index, size) in row.items {
                let isLast = index == subviews.count - 1
                let width = isLast ? bounds.maxX - x : size.width
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2), anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: size.height))
                x += width + spacing.points
            }
            y += row.height + spacing.points
        }
    }

    private struct Row {
        var items: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        private func gap(_ spacing: ChipSpacing) -> CGFloat {
            items.isEmpty ? 0 : spacing.points
        }

        /// An empty line takes anything.
        func fits(_ size: CGSize, _ spacing: ChipSpacing, _ line: LineWidth) -> Bool {
            items.isEmpty || width + gap(spacing) + size.width <= line.points
        }

        mutating func add(_ index: Int, _ size: CGSize, _ spacing: ChipSpacing) {
            width += gap(spacing) + size.width
            height = max(height, size.height)
            items.append((index, size))
        }
    }

    private func arrange(_ subviews: Subviews, within line: LineWidth) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > line.points {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: line.points, height: nil))
            }
            if !rows[rows.count - 1].fits(size, spacing, line) { rows.append(Row()) }
            rows[rows.count - 1].add(index, size, spacing)
        }
        return rows
    }
}
