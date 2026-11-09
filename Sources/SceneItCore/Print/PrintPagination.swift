import CoreGraphics

/// A distance on paper in points (1/72 in), never negative. NaN is zero, so ordering is total.
public struct PaperLength: Hashable, Comparable, Sendable {
    public let points: CGFloat

    public init(_ points: CGFloat) {
        self.points = points.isNaN ? 0 : max(points, 0) + 0
    }

    public static let zero = Self(0)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.points < rhs.points
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(lhs.points + rhs.points)
    }

    /// Zero when `rhs` is the longer.
    public static func - (lhs: Self, rhs: Self) -> Self {
        Self(lhs.points - rhs.points)
    }
}

extension CGFloat {
    public init(_ length: PaperLength) {
        self = length.points
    }
}

/// One line of the printed text, measured down the text as one continuous column.
public struct PrintLine: Hashable, Sendable {
    /// The top of its letters.
    public let top: PaperLength
    /// The bottom of its letters; the spacing below them belongs to the page it's on.
    public let bottom: PaperLength
    public let start: LineStart

    public enum LineStart: Hashable, Sendable {
        case continuing
        /// It begins a scene, so it begins a page.
        case newPage
    }

    public init(top: PaperLength, bottom: PaperLength, start: LineStart = .continuing) {
        self.top = top
        self.bottom = max(top, bottom)
        self.start = start
    }
}

/// A comment to print in the margin column, beside the line its text starts on.
public struct MarginComment: Hashable, Sendable {
    /// The index of that line.
    public let line: Int
    public let height: PaperLength

    public init(line: Int, height: PaperLength) {
        self.line = line
        self.height = height
    }
}

/// A printed page: a stretch of the text's lines, and the comments its column holds.
public struct PrintPage: Hashable, Sendable {
    /// Empty on a page that only carries comments over.
    public let lines: Range<Int>
    /// Top to bottom, none overlapping another.
    public let comments: [PlacedComment]
}

public struct PlacedComment: Hashable, Sendable {
    /// Its index among the comments given.
    public let comment: Int
    /// Down from the top of the column, which is level with the top of the page's text.
    public let top: PaperLength
    /// At most the column's height.
    public let height: PaperLength
    public let anchor: Anchor

    public enum Anchor: Hashable, Sendable {
        /// Its line is on this page.
        case onPage
        /// Its line is on an earlier page, whose column had no room left for it.
        case carriedOver
    }

    public var bottom: PaperLength {
        top + height
    }
}

/// Where the printed text breaks into pages and where each comment goes in the margin column
/// (PLAN §10.1). A comment is level with the top of its line unless the comment above pushes it
/// down; one that would run past the column's end takes its line to the next page with it, so a
/// comment is never split. Only comments that can't fit even beside a line at the top of a page
/// (one line with more comments than a column holds) are carried over, to the top of the next
/// page's column, in order.
public enum PrintPagination {
    /// `lines` in order down the text; `comments` in any order, each kept in its line's order.
    /// `height` is the height of a page's text and of its column, and `spacing` the room kept
    /// between two comments. A comment taller than the column is placed as tall as it.
    public static func pages(
        lines: [PrintLine], comments: [MarginComment], height: PaperLength, spacing: PaperLength
    ) -> [PrintPage] {
        let byLine = Dictionary(
            grouping: comments.indices.filter { lines.indices.contains(comments[$0].line) }
        ) {
            comments[$0].line
        }
        func size(_ comment: Int) -> PaperLength {
            min(comments[comment].height, height)
        }
        var pages: [PrintPage] = []
        var next = 0
        var carried: [Int] = []
        while next < lines.count || !carried.isEmpty {
            let first = next
            let pageTop = next < lines.count ? lines[next].top : .zero
            var column = Column(height: height, spacing: spacing)
            var waiting = column.place(carried, at: .zero, sizedBy: size, anchored: .carriedOver)
            while next < lines.count {
                let line = lines[next]
                let ownComments = byLine[next] ?? []
                if next > first && (line.start == .newPage || line.bottom - pageTop > height) { break }
                var trial = column
                // Behind a comment still waiting, the line's own wait too, so none jumps the queue.
                let left =
                    waiting.isEmpty
                    ? trial.place(ownComments, at: line.top - pageTop, sizedBy: size, anchored: .onPage)
                    : ownComments
                if !left.isEmpty && next > first { break }
                column = trial
                waiting += left
                next += 1
            }
            pages.append(PrintPage(lines: first..<next, comments: column.placed))
            carried = waiting
        }
        return pages
    }

    /// A page's comment column as it fills.
    private struct Column {
        let height: PaperLength
        let spacing: PaperLength
        private(set) var placed: [PlacedComment] = []

        init(height: PaperLength, spacing: PaperLength) {
            self.height = height
            self.spacing = spacing
        }

        /// Places `comments` in order, each at `level` or below the last one placed. Returns
        /// those that don't fit, from the first that doesn't on, so their order is kept. Sized to
        /// the column, a comment always fits at the top of an empty one.
        mutating func place(
            _ comments: [Int], at level: PaperLength, sizedBy size: (Int) -> PaperLength,
            anchored anchor: PlacedComment.Anchor
        ) -> [Int] {
            for (index, comment) in comments.enumerated() {
                let top = placed.last.map { max(level, $0.bottom + spacing) } ?? level
                guard top + size(comment) <= height else { return Array(comments[index...]) }
                placed.append(
                    PlacedComment(comment: comment, top: top, height: size(comment), anchor: anchor))
            }
            return []
        }
    }
}
