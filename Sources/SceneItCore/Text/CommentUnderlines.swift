import AppKit
import Synchronization

/// How many device pixels a point of the text covers where it's drawn: the display's backing
/// scale times the page's zoom.
struct DeviceStep: Hashable, Sendable {
    let pixelsPerPoint: CGFloat

    init(pixelsPerPoint: CGFloat) {
        self.pixelsPerPoint = pixelsPerPoint.isFinite ? max(pixelsPerPoint, 0.01) : 1
    }

    /// The step `context` draws at, measured down from `y`.
    init(of context: CGContext, at y: CGFloat) {
        let here = context.convertToDeviceSpace(CGPoint(x: 0, y: y))
        let below = context.convertToDeviceSpace(CGPoint(x: 0, y: y + 1))
        self.init(pixelsPerPoint: abs(below.y - here.y))
    }

    /// 100% at 1x and at 2x: a stack is never deeper than fits at both.
    static let reference = [Self(pixelsPerPoint: 1), Self(pixelsPerPoint: 2)]
}

/// How commented text is underlined (ADR 0032, the owner's pick on #24): a 1 pt line per
/// comment in its color, 3 pt below the baseline, the lines of overlapping comments stacked
/// downward 1.5 pt apart into the double spacing.
enum UnderlineStyle {
    static let thickness: CGFloat = 1
    /// The clear space between two stacked lines.
    static let spacing: CGFloat = 1.5
    /// From the baseline down to the top of the first line.
    static let offset: CGFloat = 3

    /// What the deepest line keeps clear of the next line's letters' slot (its cursor and its
    /// selection band).
    static let clearance: CGFloat = 1

    /// The top of the line at `level`, below the baseline, before it meets the pixels.
    static func top(of level: Int) -> CGFloat {
        offset + CGFloat(level) * (thickness + spacing)
    }

    /// The line at `level` in device pixels below the baseline's pixel: its thickness and its
    /// distance from the line above are each rounded to whole pixels, so a stack is even.
    static func pixels(of level: Int, at step: DeviceStep) -> (top: Int, height: Int) {
        let perPoint = step.pixelsPerPoint
        let height = max(1, Int((thickness * perPoint).rounded()))
        let pitch = max(height + 1, Int(((thickness + spacing) * perPoint).rounded()))
        return (Int((offset * perPoint).rounded()) + level * pitch, height)
    }

    /// From the baseline down to what the lines below `line` must keep clear of: the next
    /// line's slot, which `paragraph`'s line spacing puts below it.
    static func room(below line: NSTextLineFragment, spacedBy paragraph: NSParagraphStyle) -> CGFloat {
        line.typographicBounds.height - line.glyphOrigin.y + paragraph.lineSpacing - clearance
    }

    /// How many lines fit below `line` at `step` and at the reference steps: none, if not even
    /// one does. Half a pixel is kept spare, for the baseline's rounding to its pixel.
    static func depth(
        below line: NSTextLineFragment, spacedBy paragraph: NSParagraphStyle, at step: DeviceStep?
    ) -> Int {
        let room = room(below: line, spacedBy: paragraph)
        let steps = DeviceStep.reference + (step.map { [$0] } ?? [])
        return steps.map { step in
            (0...).first { level in
                let line = pixels(of: level, at: step)
                return CGFloat(line.top + line.height) > room * step.pixelsPerPoint - 0.5
            } ?? 0
        }.min() ?? 0
    }
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
            let ids = ids(in: value)
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

    /// The comments covering the character at `index` of `text`, newest first; none past its end.
    public func newestFirst(at index: Int, in text: NSAttributedString) -> [CommentID] {
        guard index >= 0, index < text.length else { return [] }
        return ids(in: text.attribute(.comments, at: index, effectiveRange: nil))
            .sorted { age(of: $0) > age(of: $1) }
    }

    /// Whether this palette has `comment`.
    public func covers(_ comment: CommentID) -> Bool {
        entries[comment] != nil
    }

    /// Whether a comment this palette has covers any of `text`.
    func covers(_ text: NSAttributedString) -> Bool {
        var covered = false
        text.enumerateAttribute(.comments, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if !ids(in: value).isEmpty {
                covered = true
                stop.pointee = true
            }
        }
        return covered
    }

    /// The comments drawn differently with `other`: added, removed or recolored, or older or
    /// newer than they were.
    func changes(to other: Self) -> Set<CommentID> {
        Set(entries.keys).union(other.entries.keys).filter { entries[$0] != other.entries[$0] }
    }

    /// The ids in a `.comments` value.
    static func ids(in value: Any?) -> Set<CommentID> {
        (value as? NSSet).flatMap { try? NovelAttributes.CommentsAttribute.value(for: $0) } ?? []
    }

    /// The ids in a `.comments` value that this palette has.
    private func ids(in value: Any?) -> [CommentID] {
        Self.ids(in: value).filter { entries[$0] != nil }
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
    /// TextKit keeps a fragment when its layout is invalidated, so it reads the palette from
    /// here each time rather than keeping the one it was made with.
    private let underliner: CommentUnderliner
    private let drawn = Mutex<[CommentUnderline]>([])

    /// The underlines this fragment last drew, in its paragraph's offsets: evidence for tests of
    /// what the page shows, since TextKit keeps a paragraph's drawing until it draws it again.
    var lastDrawn: [CommentUnderline] {
        drawn.withLock(\.self)
    }

    init(_ element: NSTextElement, range: NSTextRange?, underliner: CommentUnderliner) {
        self.underliner = underliner
        super.init(textElement: element, range: range)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private var text: NSAttributedString? {
        (textElement as? NSTextParagraph)?.attributedString
    }

    private var paragraphStyle: NSParagraphStyle {
        guard let text, text.length > 0 else { return .default }
        return text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle ?? .default
    }

    private func baseline(of line: NSTextLineFragment) -> CGFloat {
        line.typographicBounds.minY + line.glyphOrigin.y
    }

    /// One underline where it's drawn: `rect` is where it is before it meets the pixels.
    struct PlacedUnderline {
        /// The characters it's under, in the paragraph.
        let span: NSRange
        let rect: CGRect
        let baseline: CGFloat
        let level: Int
        let color: PaletteColor
    }

    /// The underlines' rectangles, in this fragment's coordinates, as deep as fits at `step`.
    /// A line that ends a wrapped line stops at its last letter, not under the space it breaks at.
    func underlineRects(at step: DeviceStep? = nil) -> [PlacedUnderline] {
        guard let text, let first = textLineFragments.first else { return [] }
        let depth = UnderlineStyle.depth(below: first, spacedBy: paragraphStyle, at: step)
        let underlines = underliner.palette.underlines(of: text, depth: max(depth, 1))
        guard !underlines.isEmpty else { return [] }
        let string = text.string as NSString
        var rects: [PlacedUnderline] = []
        for line in textLineFragments {
            for underline in underlines {
                guard var span = underline.range.intersection(line.characterRange), span.length > 0 else {
                    continue
                }
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
                        span: span,
                        rect: CGRect(
                            x: line.typographicBounds.minX + from,
                            y: baseline(of: line) + UnderlineStyle.top(of: underline.level),
                            width: to - from, height: UnderlineStyle.thickness),
                        baseline: baseline(of: line), level: underline.level, color: underline.color))
            }
        }
        return rects
    }

    private var isCommented: Bool {
        text.map(underliner.palette.covers) ?? false
    }

    // MARK: Hit-testing

    /// Where a line answers a click: from the top of its letters' slot down to the end of the
    /// room below it, where its underlines are.
    private func band(of line: NSTextLineFragment) -> Range<CGFloat> {
        let bottom = baseline(of: line) + UnderlineStyle.room(below: line, spacedBy: paragraphStyle)
        return line.typographicBounds.minY..<max(bottom, line.typographicBounds.maxY)
    }

    /// The character of this paragraph under `point`, in this fragment's coordinates, on a line
    /// whose band holds it: its offset in the paragraph.
    func character(at point: CGPoint) -> Int? {
        guard let line = textLineFragments.first(where: { band(of: $0).contains(point.y) }) else {
            return nil
        }
        let x = point.x - line.typographicBounds.minX
        let range = line.characterRange
        let near = line.characterIndex(for: CGPoint(x: x, y: line.glyphOrigin.y))
        return [near - 1, near, near + 1].first { index in
            index >= range.location && index < range.upperBound && x >= line.locationForCharacter(at: index).x
                && x < line.locationForCharacter(at: index + 1).x
        }
    }

    /// The character of `layout`'s text at `point`, in its text container's coordinates: its
    /// offset in the text. The room below a paragraph's last line lies in the next paragraph's
    /// frame, so the paragraph above is asked first, then the one whose frame holds `point`.
    public static func character(at point: CGPoint, in layout: NSTextLayoutManager) -> Int? {
        guard let content = layout.textContentManager else { return nil }
        let documentStart = layout.documentRange.location
        let viewportStart = layout.textViewportLayoutController.viewportRange?.location ?? documentStart
        var aboveAndAt: [NSTextLayoutFragment] = []
        layout.enumerateTextLayoutFragments(from: viewportStart, options: [.ensuresLayout]) { fragment in
            guard fragment.layoutFragmentFrame.minY <= point.y else { return false }
            aboveAndAt = Array((aboveAndAt + [fragment]).suffix(2))
            return true
        }
        for fragment in aboveAndAt {
            let frame = fragment.layoutFragmentFrame
            if let ours = fragment as? CommentUnderlineFragment,
                let index = ours.character(at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY))
            {
                return content.offset(from: documentStart, to: fragment.rangeInElement.location) + index
            }
        }
        return nil
    }

    // MARK: Drawing

    /// A commented paragraph's lines reach below its last line, outside its frame.
    public override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds
        guard let last = textLineFragments.last, isCommented else { return bounds }
        let room = max(
            UnderlineStyle.room(below: last, spacedBy: paragraphStyle),
            UnderlineStyle.top(of: 0) + UnderlineStyle.thickness)
        let lowest = baseline(of: last) + room + UnderlineStyle.clearance
        return bounds.union(
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: lowest - bounds.minY))
    }

    public override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let first = textLineFragments.first else { return }
        let step = DeviceStep(of: context, at: point.y + baseline(of: first))
        let underlines = underlineRects(at: step)
        drawn.withLock { $0 = underlines.map { CommentUnderline($0.span, level: $0.level, color: $0.color) } }
        guard !underlines.isEmpty else { return }
        context.saveGState()
        for underline in underlines {
            context.setFillColor(underline.color.nsColor.cgColor)
            context.fill(
                pixelAligned(
                    underline, top: UnderlineStyle.pixels(of: underline.level, at: step).top, at: point,
                    step: step, in: context))
        }
        context.restoreGState()
    }

    /// `underline` on whole device pixels, `top` pixels below its baseline's pixel.
    private func pixelAligned(
        _ underline: PlacedUnderline, top: Int, at point: CGPoint, step: DeviceStep, in context: CGContext
    ) -> CGRect {
        let baseline = context.convertToDeviceSpace(CGPoint(x: 0, y: point.y + underline.baseline))
        let below = context.convertToDeviceSpace(CGPoint(x: 0, y: point.y + underline.baseline + 1))
        let down: CGFloat = below.y < baseline.y ? -1 : 1
        let height = UnderlineStyle.pixels(of: underline.level, at: step).height
        let lineTop = baseline.y.rounded() + down * CGFloat(top)
        let lineBottom = lineTop + down * CGFloat(height)
        let left = context.convertToDeviceSpace(CGPoint(x: point.x + underline.rect.minX, y: 0)).x
        let right = context.convertToDeviceSpace(CGPoint(x: point.x + underline.rect.maxX, y: 0)).x
        return context.convertToUserSpace(
            CGRect(
                x: min(left, right), y: min(lineTop, lineBottom), width: abs(right - left),
                height: CGFloat(height)))
    }
}

/// Lays out every paragraph of a text as a `CommentUnderlineFragment`, which draws with the
/// palette this was last given. TextKit asks on whichever thread lays out.
public final class CommentUnderliner: NSObject, NSTextLayoutManagerDelegate, Sendable {
    private let state = Mutex(CommentPalette.empty)

    /// Draws `palette`'s comments from now on. The text whose comments changed is laid out
    /// again; returns it, for the view to draw again, since TextKit keeps a paragraph's drawing
    /// when only its fragment's layout changes.
    @discardableResult
    public func show(_ palette: CommentPalette, laidOutBy layout: NSTextLayoutManager?) -> [NSTextRange] {
        let changed = state.withLock { current in
            let changed = current.changes(to: palette)
            current = palette
            return changed
        }
        guard !changed.isEmpty, let layout else { return [] }
        return invalidate(changed, in: layout)
    }

    public var palette: CommentPalette {
        state.withLock(\.self)
    }

    private func invalidate(_ comments: Set<CommentID>, in layout: NSTextLayoutManager) -> [NSTextRange] {
        guard let content = layout.textContentManager as? NSTextContentStorage,
            let text = content.attributedString
        else { return [] }
        var invalidated: [NSTextRange] = []
        let start = layout.documentRange.location
        text.enumerateAttribute(.comments, in: NSRange(location: 0, length: text.length)) { value, run, _ in
            guard !CommentPalette.ids(in: value).isDisjoint(with: comments),
                let from = content.location(start, offsetBy: run.location),
                let to = content.location(from, offsetBy: run.length),
                let range = NSTextRange(location: from, end: to)
            else { return }
            layout.invalidateLayout(for: range)
            invalidated.append(range)
        }
        return invalidated
    }

    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        CommentUnderlineFragment(textElement, range: textElement.elementRange, underliner: self)
    }
}
