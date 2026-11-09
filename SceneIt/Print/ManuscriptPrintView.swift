import AppKit
import SceneItCore

/// The printed manuscript (PLAN §10.1): its pages stacked top to bottom, a sheet of paper each,
/// which `NSPrintOperation` prints a page at a time. It lays the pages out again whenever the
/// print dialog's choices or its paper change, as the dialog's preview asks for them.
final class ManuscriptPrintView: NSView {
    private let book: Book
    private let openScene: SceneID?
    let choices: PrintChoices
    private(set) var pages: ManuscriptPages?
    private var laidOutFor: (layout: PrintLayout, range: PrintRange, paper: CGSize)?

    init(book: Book, openScene: SceneID?, choices: PrintChoices) {
        self.book = book
        self.openScene = openScene
        self.choices = choices
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    /// The pages for `printInfo`'s paper, laid out again only if they've changed.
    @discardableResult
    func layOut(for printInfo: NSPrintInfo) -> ManuscriptPages {
        let paper = Self.paper(of: printInfo)
        if let pages, let laidOutFor, laidOutFor.layout == choices.layout, laidOutFor.range == choices.range,
            laidOutFor.paper == paper
        {
            return pages
        }
        let laidOut = ManuscriptPages(
            PrintManuscript(choices.range.scenes(of: book, open: openScene)), layout: choices.layout,
            paper: paper)
        pages = laidOut
        laidOutFor = (choices.layout, choices.range, paper)
        setFrameSize(NSSize(width: paper.width, height: paper.height * CGFloat(laidOut.pageCount)))
        return laidOut
    }

    /// The sheet's size as it's turned: `NSPrintInfo` keeps the paper's size the way it's fed.
    static func paper(of printInfo: NSPrintInfo) -> CGSize {
        let size = printInfo.paperSize
        let (short, long) = (min(size.width, size.height), max(size.width, size.height))
        return switch printInfo.orientation {
        case .landscape: CGSize(width: long, height: short)
        default: CGSize(width: short, height: long)
        }
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        let pages = layOut(for: NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared)
        range.pointee = NSRange(location: 1, length: pages.pageCount)
        return true
    }

    /// Page `number`, counted from 1, as a whole sheet: the print info has no margins, so the
    /// pages draw their own.
    override func rectForPage(_ number: Int) -> NSRect {
        guard let paper = pages?.geometry.paper else { return .zero }
        return NSRect(x: 0, y: CGFloat(number - 1) * paper.height, width: paper.width, height: paper.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pages, let context = NSGraphicsContext.current else { return }
        for index in 0..<pages.pageCount {
            let sheet = rectForPage(index + 1)
            guard sheet.intersects(dirtyRect) else { continue }
            context.saveGraphicsState()
            let shift = NSAffineTransform()
            shift.translateX(by: 0, yBy: sheet.minY)
            shift.concat()
            pages.draw(page: index, in: context)
            context.restoreGraphicsState()
        }
    }
}
