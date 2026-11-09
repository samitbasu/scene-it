import AppKit

/// Where things go on a printed sheet (PLAN §10.1), in points from its top left corner.
public struct PrintGeometry: Hashable, Sendable {
    public let paper: CGSize
    /// The text column: as wide as the page's on screen, so lines break where they do there,
    /// unless the paper is too narrow.
    public let text: CGRect
    /// The comments' column, level with the text; `nil` for text only.
    public let comments: CGRect?

    static let margin: CGFloat = 72
    /// Right of the comments' column.
    static let outerMargin: CGFloat = 36
    static let gutter: CGFloat = 18
    /// From the top of the sheet to the top of the page number.
    static let pageNumberTop: CGFloat = 36
    /// The page's 6.5 in text column.
    static let textWidth: CGFloat = 468

    public init(paper: CGSize, layout: PrintLayout) {
        self.paper = paper
        let height = max(paper.height - 2 * Self.margin, 1)
        switch layout {
        case .textOnly:
            text = CGRect(
                x: Self.margin, y: Self.margin,
                width: max(min(Self.textWidth, paper.width - 2 * Self.margin), 1),
                height: height)
            comments = nil
        case .withComments:
            let columnWidth = (paper.width / 4).rounded()
            let room = paper.width - Self.margin - Self.gutter - columnWidth - Self.outerMargin
            text = CGRect(
                x: Self.margin, y: Self.margin, width: max(min(Self.textWidth, room), 1), height: height)
            comments = CGRect(
                x: paper.width - Self.outerMargin - columnWidth, y: Self.margin, width: columnWidth,
                height: height)
        }
    }

    /// The right edge of what's printed, which the page number ends at.
    var rightEdge: CGFloat {
        comments?.maxX ?? text.maxX
    }
}

/// How the margin column's comments look (PLAN §10.1): each a box with a bar in its colour, a
/// thin connector running to its underlined text.
@MainActor
enum MarginStyle {
    static let font = NSFont.systemFont(ofSize: 9)
    static let barWidth: CGFloat = 3
    /// Between the bar and the text, and right of the text.
    static let horizontalPadding: CGFloat = 5
    static let verticalPadding: CGFloat = 3
    static let spacing = PaperLength(6)
    static let fillOpacity: CGFloat = 0.08
    static let connectorWidth: CGFloat = 0.5
    static let connectorDash: [CGFloat] = [1, 1.5]
    static let ruleColor = NSColor(white: 0.7, alpha: 1)
    static let ruleWidth: CGFloat = 0.5
    static let ruleDash: [CGFloat] = [2, 2]
}

/// A manuscript laid out on paper and broken into pages (PLAN §10.1), ready to draw a page at a
/// time. The text is laid out by TextKit 2, as on the page: the same fragments, so the same
/// spacing and comment underlines.
@MainActor
public final class ManuscriptPages {
    public let geometry: PrintGeometry
    public let pages: [PrintPage]
    private let content: NSTextContentStorage
    private let layout: NSTextLayoutManager
    private let underliner = CommentUnderliner()
    private let fragments: [NSTextLayoutFragment]
    private let lines: [MeasuredLine]
    private let textBottom: CGFloat
    private let notes: [MarginNote]
    private let pageNumberStyle: [NSAttributedString.Key: Any]

    /// One line of the text, in the text's own coordinates.
    struct MeasuredLine {
        let top: CGFloat
        let bottom: CGFloat
        let baseline: CGFloat
        /// In the text.
        let characters: NSRange
        let line: NSTextLineFragment
        let fragmentFrame: CGRect
    }

    /// A comment ready for the margin.
    struct MarginNote {
        let comment: PrintComment
        let text: NSAttributedString
        let height: CGFloat
        let line: Int
        /// Where its connector starts, the end of its underline's first stretch on its line, in
        /// the text's coordinates.
        let target: CGPoint
    }

    public convenience init(_ manuscript: PrintManuscript, layout: PrintLayout, paper: CGSize) {
        self.init(manuscript, geometry: PrintGeometry(paper: paper, layout: layout))
    }

    init(_ manuscript: PrintManuscript, geometry: PrintGeometry) {
        self.geometry = geometry
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: geometry.text.width, height: 0))
        container.lineFragmentPadding = 0
        layout.textContainer = container
        layout.delegate = underliner
        let printsComments = geometry.comments != nil
        underliner.show(printsComments ? manuscript.palette : .empty, laidOutBy: nil)
        content.textStorage?.setAttributedString(manuscript.text)
        layout.ensureLayout(for: layout.documentRange)
        self.content = content
        self.layout = layout

        var fragments: [NSTextLayoutFragment] = []
        var lines: [MeasuredLine] = []
        let start = layout.documentRange.location
        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            fragments.append(fragment)
            let frame = fragment.layoutFragmentFrame
            let paragraph = content.offset(from: start, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds
                let top = frame.minY + bounds.minY
                lines.append(
                    MeasuredLine(
                        top: top, bottom: top + bounds.height, baseline: top + line.glyphOrigin.y,
                        characters: NSRange(
                            location: paragraph + line.characterRange.location,
                            length: line.characterRange.length),
                        line: line, fragmentFrame: frame))
            }
            return true
        }
        self.fragments = fragments
        self.lines = lines
        textBottom = fragments.last.map { $0.layoutFragmentFrame.maxY } ?? 0

        let columnWidth = geometry.comments?.width ?? 0
        notes =
            printsComments
            ? manuscript.comments.compactMap { Self.note($0, among: lines, width: columnWidth) } : []
        let printLines = lines.map { line in
            PrintLine(
                top: PaperLength(line.top), bottom: PaperLength(line.bottom),
                start: manuscript.sceneStarts.contains(line.characters.location) ? .newPage : .continuing)
        }
        let paged = PrintPagination.pages(
            lines: printLines,
            comments: notes.map { MarginComment(line: $0.line, height: PaperLength($0.height)) },
            height: PaperLength(geometry.text.height), spacing: MarginStyle.spacing)
        pages = paged.isEmpty ? [PrintPage(lines: 0..<0, comments: [])] : paged
        pageNumberStyle = [.font: ParagraphRole.body.font([]), .foregroundColor: NSColor.black]
    }

    /// `comment` measured for a column `width` wide, beside the line its first stretch starts on.
    private static func note(_ comment: PrintComment, among lines: [MeasuredLine], width: CGFloat)
        -> MarginNote?
    {
        let stretch = comment.firstStretch
        guard
            let index = lines.firstIndex(where: {
                NSLocationInRange(stretch.location, $0.characters)
            })
        else { return nil }
        let line = lines[index]
        let paragraphStart = line.characters.location - line.line.characterRange.location
        let string = line.line.attributedString.string as NSString
        var end = min(stretch.upperBound, line.characters.upperBound) - paragraphStart
        while end > stretch.location - paragraphStart + 1,
            let scalar = Unicode.Scalar(string.character(at: end - 1)),
            CharacterSet.whitespaces.contains(scalar)
        {
            end -= 1
        }
        let x =
            line.fragmentFrame.minX + line.line.typographicBounds.minX
            + line.line.locationForCharacter(at: end).x
        let text = NSAttributedString(
            string: comment.text,
            attributes: [.font: MarginStyle.font, .foregroundColor: NSColor.black])
        let textWidth = width - MarginStyle.barWidth - 2 * MarginStyle.horizontalPadding
        let measured = text.boundingRect(
            with: CGSize(width: max(textWidth, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return MarginNote(
            comment: comment, text: text,
            height: measured.height.rounded(.up) + 2 * MarginStyle.verticalPadding,
            line: index, target: CGPoint(x: x, y: line.baseline + UnderlineStyle.top(of: 0)))
    }

    public var pageCount: Int {
        pages.count
    }

    /// The top of line `index`, down the text, for tests.
    func lineTop(_ index: Int) -> CGFloat {
        lines[index].top
    }

    /// The line comment `index` is beside, for tests.
    func noteLine(_ index: Int) -> Int {
        notes[index].line
    }

    /// The comment boxes of page `index`, top to bottom, in the sheet's coordinates.
    public func commentBoxes(onPage index: Int) -> [CGRect] {
        guard let column = geometry.comments else { return [] }
        return pages[index].comments.map { box($0, in: column) }
    }

    private func box(_ placed: PlacedComment, in column: CGRect) -> CGRect {
        CGRect(
            x: column.minX, y: column.minY + CGFloat(placed.top), width: column.width,
            height: CGFloat(placed.height))
    }

    /// Where the text at `top` down the text goes on a page whose text starts at `pageTop`.
    private func sheetY(_ top: CGFloat, pageTop: CGFloat) -> CGFloat {
        geometry.text.minY + top - pageTop
    }

    /// Draws page `index` of the sheets into `context`, which must be flipped, with the sheet's
    /// top left corner at the origin.
    public func draw(page index: Int, in context: NSGraphicsContext) {
        guard pages.indices.contains(index) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let page = pages[index]
        let pageTop = page.lines.isEmpty ? 0 : lines[page.lines.lowerBound].top
        if !page.lines.isEmpty {
            let sliceBottom =
                page.lines.upperBound < lines.count ? lines[page.lines.upperBound].top : textBottom
            drawText(from: pageTop, to: sliceBottom, in: context.cgContext)
        }
        if let column = geometry.comments {
            drawRule(beside: column, in: context.cgContext)
            for placed in page.comments {
                draw(placed, in: column, pageTop: pageTop, context: context.cgContext)
            }
        }
        let number = NSAttributedString(string: "\(index + 1)", attributes: pageNumberStyle)
        number.draw(at: CGPoint(x: geometry.rightEdge - number.size().width, y: PrintGeometry.pageNumberTop))
    }

    /// The text from `top` down to `bottom`, which are lines' tops, so no line is cut.
    private func drawText(from top: CGFloat, to bottom: CGFloat, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let clipRight = geometry.comments.map { $0.minX - PrintGeometry.gutter / 2 } ?? geometry.paper.width
        context.clip(
            to: CGRect(x: 0, y: geometry.text.minY, width: clipRight, height: bottom - top))
        for fragment in fragments {
            let frame = fragment.layoutFragmentFrame
            guard frame.maxY > top, frame.minY < bottom else { continue }
            fragment.draw(
                at: CGPoint(x: geometry.text.minX + frame.minX, y: sheetY(frame.minY, pageTop: top)),
                in: context)
        }
    }

    private func drawRule(beside column: CGRect, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let x = column.minX - PrintGeometry.gutter / 2
        context.setStrokeColor(MarginStyle.ruleColor.cgColor)
        context.setLineWidth(MarginStyle.ruleWidth)
        context.setLineDash(phase: 0, lengths: MarginStyle.ruleDash)
        context.strokeLineSegments(between: [CGPoint(x: x, y: column.minY), CGPoint(x: x, y: column.maxY)])
    }

    private func draw(_ placed: PlacedComment, in column: CGRect, pageTop: CGFloat, context: CGContext) {
        let note = notes[placed.comment]
        let color = note.comment.color.nsColor
        let box = box(placed, in: column)
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(color.withAlphaComponent(MarginStyle.fillOpacity).cgColor)
        context.fill(box)
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: box.minX, y: box.minY, width: MarginStyle.barWidth, height: box.height))
        let textRect = CGRect(
            x: box.minX + MarginStyle.barWidth + MarginStyle.horizontalPadding,
            y: box.minY + MarginStyle.verticalPadding,
            width: box.width - MarginStyle.barWidth - 2 * MarginStyle.horizontalPadding,
            height: box.height - 2 * MarginStyle.verticalPadding)
        note.text.draw(
            with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        guard placed.anchor == .onPage else { return }
        let start = CGPoint(x: geometry.text.minX + note.target.x, y: sheetY(note.target.y, pageTop: pageTop))
        let gutter = CGPoint(x: column.minX - PrintGeometry.gutter / 2, y: start.y)
        let firstLine = MarginStyle.font.ascender - MarginStyle.font.descender
        let end = CGPoint(
            x: box.minX,
            y: min(max(start.y, box.minY + MarginStyle.verticalPadding + firstLine / 2), box.maxY))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(MarginStyle.connectorWidth)
        context.setLineDash(phase: 0, lengths: MarginStyle.connectorDash)
        context.move(to: start)
        context.addLine(to: gutter)
        context.addLine(to: end)
        context.strokePath()
    }
}
