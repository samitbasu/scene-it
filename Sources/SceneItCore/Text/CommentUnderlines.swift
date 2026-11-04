import AppKit
import Synchronization

/// How commented text is underlined (ADR 0032): a line per comment in its color, below the
/// baseline, stacked downward into the double spacing where comments overlap.
public struct UnderlineStyle: Hashable, Sendable {
    let thickness: CGFloat
    /// The clear space between two stacked lines.
    let spacing: CGFloat
    /// From the baseline down to the top of the first line.
    let offset: CGFloat
    let stroke: Stroke

    /// How a line meets the device's pixels.
    enum Stroke: Hashable, Sendable {
        /// Its thickness rounded to whole pixels, at least one.
        case wholePixels
        /// One device pixel at every scale, whatever its thickness in points.
        case hairline
    }

    /// What the deepest line keeps clear of the next line's letters' slot (its cursor and its
    /// selection band).
    static let clearance: CGFloat = 1

    /// The scales a depth must fit at: the same text is laid out the same on every display.
    static let scales = [1, 2]

    /// The top of the line at `level`, below the baseline, before it meets the pixels.
    func top(of level: Int) -> CGFloat {
        offset + CGFloat(level) * (thickness + spacing)
    }

    /// The line at `level` in device pixels below the baseline's pixel, at `scale` pixels a
    /// point. Every level is the same whole number of pixels below the last, so a stack is even.
    func pixels(of level: Int, scale: Int) -> (top: Int, height: Int) {
        let perPoint = CGFloat(scale)
        let height = stroke == .hairline ? 1 : max(1, Int((thickness * perPoint).rounded()))
        let pitch = max(height + 1, Int(((thickness + spacing) * perPoint).rounded()))
        return (Int((offset * perPoint).rounded()) + level * pitch, height)
    }

    /// From the baseline down to what the lines below `line` must keep clear of: the next
    /// line's slot, which `paragraph`'s line spacing puts below it.
    func room(below line: NSTextLineFragment, spacedBy paragraph: NSParagraphStyle) -> CGFloat {
        line.typographicBounds.height - line.glyphOrigin.y + paragraph.lineSpacing - Self.clearance
    }

    /// How many lines fit below `line` at every scale, at least one.
    func depth(below line: NSTextLineFragment, spacedBy paragraph: NSParagraphStyle) -> Int {
        let room = room(below: line, spacedBy: paragraph)
        let fitting = Self.scales.map { scale in
            (0...).first { level in
                let line = pixels(of: level, scale: scale)
                return CGFloat(line.top + line.height) > room * CGFloat(scale)
            } ?? 0
        }
        return max(1, fitting.min() ?? 1)
    }

    // Candidates for the owner's pick (#24): thickness 1, 1.5 and 2 pt clear of the descenders,
    // two spacings, and an offset through the descenders, as the system's underline is; then,
    // thinner, 1 pt and a hairline 1.5 pt apart.
    public static let thin = Self(thickness: 1, spacing: 2, offset: 3, stroke: .wholePixels)
    public static let medium = Self(thickness: 1.5, spacing: 2, offset: 3, stroke: .wholePixels)
    public static let thick = Self(thickness: 2, spacing: 2, offset: 3, stroke: .wholePixels)
    public static let mediumTight = Self(thickness: 1.5, spacing: 1, offset: 3, stroke: .wholePixels)
    public static let mediumHigh = Self(thickness: 1.5, spacing: 2, offset: 1.5, stroke: .wholePixels)
    public static let thinTight = Self(thickness: 1, spacing: 1.5, offset: 3, stroke: .wholePixels)
    public static let hairline = Self(thickness: 0.7, spacing: 1.5, offset: 3, stroke: .hairline)

    public static let standard = medium
}

/// The open scene's comments as the page draws them: each one's color, and which is newer.
public struct CommentPalette: Hashable, Sendable {
    private let entries: [CommentID: Entry]

    private struct Entry: Hashable, Sendable {
        let color: PaletteColor
        /// Higher is newer.
        let age: Int
    }

    public static let empty = Self([])

    /// Newer by creation time; of two made in the same second, the later in the list.
    public init(_ comments: [Comment]) {
        let ranked = comments.enumerated().sorted {
            ($0.element.created.secondsSince1970, $0.offset) < (
                $1.element.created.secondsSince1970, $1.offset
            )
        }
        entries = Dictionary(
            ranked.enumerated().map { age, comment in
                (comment.element.id, Entry(color: comment.element.color, age: age))
            }, uniquingKeysWith: { first, _ in first })
    }

    /// `text`'s underlines, in its own character offsets. Each comment keeps one level across
    /// the paragraph: the lowest that no comment overlapping it already has, taking them in the
    /// order they start (the older first, of two starting together). Where a stack would be
    /// deeper than `depth`, that stretch has one line instead, in the newest comment's color
    /// (ADR 0032's fallback).
    public func underlines(of text: NSAttributedString, depth: Int) -> [CommentUnderline] {
        var runs: [(range: NSRange, comments: [CommentID])] = []
        text.enumerateAttribute(.comments, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let ids = ((value as? NSSet)?.allObjects as? [String] ?? []).map(CommentID.init(rawValue:))
                .filter { entries[$0] != nil }
            if !ids.isEmpty { runs.append((range, ids)) }
        }
        let levels = levels(of: runs)
        var underlines: [CommentUnderline] = []
        for run in runs {
            let stack = run.comments.map { (id: $0, level: levels[$0, default: 0]) }
            if stack.allSatisfy({ $0.level < depth }) {
                for line in stack {
                    underlines.append(
                        CommentUnderline(run.range, level: line.level, color: color(of: line.id)))
                }
            } else if let newest = run.comments.max(by: { age(of: $0) < age(of: $1) }) {
                underlines.append(CommentUnderline(run.range, level: 0, color: color(of: newest)))
            }
        }
        return CommentUnderline.merged(underlines)
    }

    private func levels(of runs: [(range: NSRange, comments: [CommentID])]) -> [CommentID: Int] {
        var spans: [CommentID: NSRange] = [:]
        for run in runs {
            for id in run.comments {
                spans[id] = spans[id].map { $0.union(run.range) } ?? run.range
            }
        }
        let order = spans.sorted {
            ($0.value.location, age(of: $0.key)) < ($1.value.location, age(of: $1.key))
        }
        var levels: [CommentID: Int] = [:]
        var placed: [(span: NSRange, level: Int)] = []
        for (id, span) in order {
            let taken = Set(placed.filter { $0.span.intersection(span)?.length ?? 0 > 0 }.map(\.level))
            let level = (0...).first { !taken.contains($0) } ?? 0
            levels[id] = level
            placed.append((span, level))
        }
        return levels
    }

    private func color(of id: CommentID) -> PaletteColor {
        entries[id]?.color ?? .black
    }

    private func age(of id: CommentID) -> Int {
        entries[id]?.age ?? -1
    }
}

/// One comment's line under a stretch of a paragraph.
public struct CommentUnderline: Hashable, Sendable {
    public let range: NSRange
    /// 0 is nearest the text.
    public let level: Int
    public let color: PaletteColor

    init(_ range: NSRange, level: Int, color: PaletteColor) {
        self.range = range
        self.level = level
        self.color = color
    }

    /// Neighbouring stretches of the same line joined, so a line is drawn without seams.
    static func merged(_ underlines: [CommentUnderline]) -> [CommentUnderline] {
        var open: [Int: CommentUnderline] = [:]
        var merged: [CommentUnderline] = []
        for underline in underlines {
            if let previous = open[underline.level], previous.color == underline.color,
                previous.range.upperBound == underline.range.location
            {
                open[underline.level] = CommentUnderline(
                    previous.range.union(underline.range), level: underline.level, color: underline.color)
            } else {
                if let previous = open[underline.level] { merged.append(previous) }
                open[underline.level] = underline
            }
        }
        merged += open.values
        return merged.sorted { ($0.range.location, $0.level) < ($1.range.location, $1.level) }
    }
}

/// A paragraph laid out as TextKit does, with its comments' underlines drawn below its lines.
public final class CommentUnderlineFragment: NSTextLayoutFragment, @unchecked Sendable {
    /// TextKit keeps a fragment when its layout is invalidated, so it reads its palette and
    /// style from here each time rather than keeping the ones it was made with.
    private let underliner: CommentUnderliner

    private var palette: CommentPalette {
        underliner.palette
    }

    var style: UnderlineStyle {
        underliner.style
    }

    init(_ element: NSTextElement, range: NSTextRange?, underliner: CommentUnderliner) {
        self.underliner = underliner
        super.init(textElement: element, range: range)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private var paragraph: NSTextParagraph? {
        textElement as? NSTextParagraph
    }

    private func paragraphStyle(of paragraph: NSTextParagraph) -> NSParagraphStyle {
        let text = paragraph.attributedString
        let style = text.length > 0 ? text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) : nil
        return style as? NSParagraphStyle ?? .default
    }

    private func depth(of paragraph: NSTextParagraph) -> Int {
        guard let line = textLineFragments.first else { return 1 }
        return style.depth(below: line, spacedBy: paragraphStyle(of: paragraph))
    }

    /// One underline where it's drawn: `rect` is where it is before it meets the pixels.
    struct PlacedUnderline {
        let rect: CGRect
        let baseline: CGFloat
        let level: Int
        let color: PaletteColor
    }

    /// The underlines' rectangles, in this fragment's coordinates. A line that ends a wrapped
    /// line stops at its last letter, not under the space the line breaks at.
    func underlineRects() -> [PlacedUnderline] {
        guard let paragraph else { return [] }
        let text = paragraph.attributedString
        let underlines = palette.underlines(of: text, depth: depth(of: paragraph))
        guard !underlines.isEmpty else { return [] }
        let string = text.string as NSString
        var rects: [PlacedUnderline] = []
        for line in textLineFragments {
            let lineRange = line.characterRange
            let baseline = line.typographicBounds.minY + line.glyphOrigin.y
            for underline in underlines {
                guard var span = underline.range.intersection(lineRange), span.length > 0 else { continue }
                while span.length > 0,
                    CharacterSet.whitespacesAndNewlines.contains(
                        Unicode.Scalar(string.character(at: span.upperBound - 1)) ?? "x")
                {
                    span.length -= 1
                }
                guard span.length > 0 else { continue }
                let from = line.locationForCharacter(at: span.location).x
                let to = line.locationForCharacter(at: span.upperBound).x
                rects.append(
                    PlacedUnderline(
                        rect: CGRect(
                            x: line.typographicBounds.minX + from,
                            y: baseline + style.top(of: underline.level),
                            width: to - from, height: style.thickness),
                        baseline: baseline, level: underline.level, color: underline.color))
            }
        }
        return rects
    }

    /// The lines below the last line of text reach into the spacing below it, outside the frame.
    public override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds
        guard let paragraph, let last = textLineFragments.last else { return bounds }
        let lowest =
            last.typographicBounds.minY + last.glyphOrigin.y
            + style.room(below: last, spacedBy: paragraphStyle(of: paragraph)) + UnderlineStyle.clearance
        return bounds.union(
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: lowest - bounds.minY))
    }

    public override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        let underlines = underlineRects()
        guard !underlines.isEmpty else { return }
        context.saveGState()
        for underline in underlines {
            context.setFillColor(underline.color.nsColor.cgColor)
            context.fill(pixelAligned(underline, at: point, in: context))
        }
        context.restoreGState()
    }

    /// `underline` on whole device pixels, measured from its baseline's pixel, so it's crisp and
    /// a stack is evenly spaced at every scale.
    private func pixelAligned(_ underline: PlacedUnderline, at point: CGPoint, in context: CGContext)
        -> CGRect
    {
        let baseline = context.convertToDeviceSpace(CGPoint(x: 0, y: point.y + underline.baseline))
        let below = context.convertToDeviceSpace(CGPoint(x: 0, y: point.y + underline.baseline + 1))
        let step = below.y - baseline.y
        let scale = max(1, Int(abs(step).rounded()))
        let down: CGFloat = step < 0 ? -1 : 1
        let line = style.pixels(of: underline.level, scale: scale)
        let top = baseline.y.rounded() + down * CGFloat(line.top)
        let bottom = top + down * CGFloat(line.height)
        let left = context.convertToDeviceSpace(CGPoint(x: point.x + underline.rect.minX, y: 0)).x
        let right = context.convertToDeviceSpace(CGPoint(x: point.x + underline.rect.maxX, y: 0)).x
        return context.convertToUserSpace(
            CGRect(
                x: min(left, right), y: min(top, bottom), width: abs(right - left),
                height: CGFloat(line.height)))
    }
}

/// Lays out every paragraph of a text as a `CommentUnderlineFragment`, which draws with the
/// palette and style this was last given. TextKit asks on whichever thread lays out.
public final class CommentUnderliner: NSObject, NSTextLayoutManagerDelegate, Sendable {
    private let state = Mutex((palette: CommentPalette.empty, style: UnderlineStyle.standard))

    /// Draws `palette`'s comments in `style` from now on, laying `layout`'s text out again if
    /// either changed.
    public func show(
        _ palette: CommentPalette, in style: UnderlineStyle, laidOutBy layout: NSTextLayoutManager?
    ) {
        let changed = state.withLock { state in
            guard state.palette != palette || state.style != style else { return false }
            state = (palette, style)
            return true
        }
        if changed, let layout { layout.invalidateLayout(for: layout.documentRange) }
    }

    public var palette: CommentPalette {
        state.withLock(\.palette)
    }

    public var style: UnderlineStyle {
        state.withLock(\.style)
    }

    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        CommentUnderlineFragment(textElement, range: textElement.elementRange, underliner: self)
    }
}
