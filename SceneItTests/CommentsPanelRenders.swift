import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// The comments panel (#25) in the window at 100%, beside mockups 02 to 04, for the owner's
/// look approval: cards with one selected, the ⋯ menu, #red filtering, the Detached group, a
/// card being edited, the empty state and the floating Comment button, with the candidates
/// where the mockup leaves a choice open. In a `comments/` subfolder.
extension WindowRenders {
    static let commentMockup = "02-select-to-comment.png"
    static let commentMenuMockup = "03-comment-menu.png"
    static let commentSearchMockup = "04-comment-search-color.png"

    /// The first scene with the mockup's two comments, two more, and two detached.
    static func commentedBook() -> Book {
        var book = sampleBook()
        let created = Timestamp(.now, in: .current)
        let comments: [(String, PaletteColor, String)] = [
            ("c1", .purple, "Too early for this reveal?"),
            ("c2", .red, "Check the ferry schedule for the 1950s."),
            ("c3", .blue, "Does she ever look back? Maybe one line about the lighthouse."),
            ("c4", .red, "Swore at it, or at her?"),
            ("c5", .gray, "There was a dream here. Bring it back in scene 4?"),
            ("c6", .green, "Mother's name?"),
        ]
        book.scenes[0].comments = comments.map {
            .init(id: CommentID(rawValue: $0.0), color: $0.1, text: $0.2, created: created)
        }
        func id(_ raw: String) -> Set<CommentID> { [CommentID(rawValue: raw)] }
        book.scenes[0].body = [
            [
                Run("The ferry left at dawn", comments: id("c2")),
                Run(", and Mara watched the "),
                Run("harbor lights go out one by one behind her", comments: id("c3")),
                Run("."),
            ],
            [
                Run(
                    "She had packed in the dark, by feel, the way she used to as a girl when the house was "
                        + "asleep and leaving still seemed like a game.")
            ],
            [
                Run("Halfway across, the engine coughed and the deckhand "),
                Run("swore at it", comments: id("c4")),
                Run(" in a language she half remembered. He found the "),
                Run("letter", comments: id("c1")),
                Run(" under the bench an hour later, but by then she was already ashore."),
            ],
        ]
        return book
    }

    @Test func commentsPanel() async throws {
        let output = try #require(renderFolder).appending(path: "comments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSampleBook(Self.commentedBook()) { store, book, preferences in
            preferences.reveal(.comments)
            let scene = try #require(book.openScene)
            let window = {
                BookWindow(
                    book: book, store: store, preferences: preferences,
                    formatting: EditorFormatting(preferences: preferences), mode: .constant(.page))
            }
            @MainActor func state(
                _ name: String, _ caption: String, beside mockup: String = WindowRenders.commentMockup,
                popover: PopoverCapture = .none, _ prepare: @escaping (NSWindow) async throws -> Void
            ) async throws {
                let renders = try await Self.renderWithPopover(window(), popover: popover, preparing: prepare)
                try Self.write(renders, name: name, caption: caption, to: output, beside: mockup)
                try Self.png(Self.closeUp(renders.double, Self.panelRect))
                    .write(to: output.appending(path: "\(name)-panel@2x.png"))
            }

            /// A plain click on the letter on the page, as `ManuscriptTextView.mouseDown` hands it on.
            @MainActor func clickLetter(_ window: NSWindow) throws {
                let page = try #require(Self.page(in: window))
                let letter = (page.string as NSString).range(of: "letter")
                try #require(letter.location != NSNotFound, "precondition: the letter is on the page")
                window.makeFirstResponder(page)
                page.setSelectedRange(NSRange(location: letter.location + 2, length: 0))
                page.editor?.clickedComments(at: letter.location + 2)
            }

            for selected in [CommentPanelCandidates.SelectedCard.ring, .tinted] {
                CommentPanelCandidates.selectedCard = selected
                try await state(
                    "cards-selected-\(selected)",
                    "Cards in text order; the letter's selected from the page (\(selected))", clickLetter)
            }
            CommentPanelCandidates.selectedCard = .ring

            for anchor in [CommentPanelCandidates.MenuAnchor.card, .button] {
                CommentPanelCandidates.menuAnchor = anchor
                try await state(
                    "menu-open-\(anchor)", "The \u{22EF} menu, hanging from the \(anchor)",
                    beside: Self.commentMenuMockup, popover: .comment
                ) { window in
                    try clickLetter(window)
                    Self.editorOfPage(window)?.comments.openMenu(of: CommentID(rawValue: "c1"), in: scene)
                }
            }
            CommentPanelCandidates.menuAnchor = .card

            try await state(
                "menu-open-detached", "A detached card's \u{22EF} menu: Re-anchor to Selection",
                popover: .comment
            ) { window in
                Self.editorOfPage(window)?.comments.select(CommentID(rawValue: "c5"), in: scene)
                Self.editorOfPage(window)?.comments.openMenu(of: CommentID(rawValue: "c5"), in: scene)
            }

            try await state("search-red", "#red ferry, then #red", beside: Self.commentSearchMockup) {
                window in
                try Self.typeInSearch("#red ferry", in: window)
            }
            try await state("search-red-only", "#red", beside: Self.commentSearchMockup) { window in
                try Self.typeInSearch("#red", in: window)
            }
            try await state("search-unknown", "#mauve: an unknown color", beside: Self.commentSearchMockup) {
                window in
                try Self.typeInSearch("#mauve letter", in: window)
            }

            for header in [CommentPanelCandidates.DetachedHeader.label, .withHint] {
                CommentPanelCandidates.detachedHeader = header
                try await state("detached-\(header)", "The Detached group (\(header))") { window in
                    let page = try #require(Self.page(in: window))
                    page.scrollRangeToVisible(NSRange(location: 0, length: 0))
                }
            }
            CommentPanelCandidates.detachedHeader = .withHint

            try await state("comment-button", "Text selected on the page: the floating button, + enabled") {
                window in
                let page = try #require(Self.page(in: window))
                window.makeFirstResponder(page)
                let packed = (page.string as NSString).range(of: "he had packed in the dark, by feel, the")
                page.setSelectedRange(packed)
            }
            try await state(
                "comment-button-margin",
                "Candidate: the floating button in the right margin, level with the line"
            ) { window in
                let page = try #require(Self.page(in: window))
                window.makeFirstResponder(page)
                let packed = (page.string as NSString).range(of: "he had packed in the dark, by feel, the")
                page.setSelectedRange(packed)
                try await Task.sleep(for: .milliseconds(200))
                let end = try #require(page.selectionBands.last)
                let button = page.commentButton
                button.frame.origin = NSPoint(
                    x: page.pageRect.maxX - WindowMetrics.pageMargin + 8,
                    y: end.minY + (end.height - button.frame.height) / 2 - 8)
            }

            // Last on this scene: what it types stays in the book.
            try await state("card-editing", "Typing in a card: its text on the page is selected") { window in
                Self.editorOfPage(window)?.comments.open(CommentID(rawValue: "c4"), in: scene)
                try await Task.sleep(for: .milliseconds(300))
                let card = try #require(
                    subviewTree(of: window.contentView).compactMap { $0 as? CommentTextView }.first {
                        $0.window?.firstResponder === $0
                    }, "precondition: a card has the focus")
                card.insertText(" Or at the engine?", replacementRange: card.selectedRange())
            }

            book.select(try #require(book.book.scenes.dropFirst().first?.id))
            try await state("empty", "A scene with no comments") { _ in }
            _ = scene
        }
    }

    private static func editorOfPage(_ window: NSWindow) -> SceneTextEditor? {
        page(in: window)?.editor
    }

    /// The panel and a little of the page, in the window's top-left points.
    static let panelRect = CGRect(x: 1440 - 420, y: 0, width: 420, height: 900)

    enum PopoverCapture {
        case none, comment
    }

    /// Like `render`, with the popover the preparation opened, if any, drawn over the window where
    /// it stands.
    static func renderWithPopover(
        _ view: some View, popover: PopoverCapture, preparing prepare: (NSWindow) async throws -> Void
    ) async throws -> Renders {
        try await withWindow(view, in: KeyWindow.self, preparing: prepare) { window in
            let frameView = try #require(window.contentView?.superview)
            let popovers =
                popover == .none
                ? []
                : NSApp.windows.filter { $0 !== window && $0.isVisible && $0.className.contains("Popover") }
            if popover != .none { try #require(!popovers.isEmpty, "precondition: the popover is up") }
            // The popover's own content, drawn where it stands; its chrome, a material that
            // draws wrongly offscreen, stands in as a plain rounded panel.
            @MainActor func draw(_ scale: Int) -> NSBitmapImageRep {
                let rep = bitmap(of: frameView, scale: scale)
                guard let popoverWindow = popovers.first, let content = popoverWindow.contentView else {
                    return rep
                }
                let over = bitmap(of: content, scale: scale)
                let inWindow = content.convert(content.bounds, to: nil)
                let rect = NSRect(
                    origin: NSPoint(
                        x: popoverWindow.frame.minX - window.frame.minX + inWindow.minX,
                        y: popoverWindow.frame.minY - window.frame.minY + inWindow.minY),
                    size: inWindow.size)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                let chrome = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
                let shadow = NSShadow()
                shadow.shadowColor = .black.withAlphaComponent(0.18)
                shadow.shadowBlurRadius = 12
                shadow.shadowOffset = NSSize(width: 0, height: -4)
                NSGraphicsContext.saveGraphicsState()
                shadow.set()
                NSColor.white.setFill()
                chrome.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSColor.black.withAlphaComponent(0.12).setStroke()
                chrome.stroke()
                over.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
                return rep
            }
            let renders = Renders(single: draw(1), double: draw(2), triple: draw(3))
            for popoverWindow in popovers { popoverWindow.orderOut(nil) }
            return renders
        }
    }

    /// Types `text` into the comments panel's search field, through its field editor.
    static func typeInSearch(_ text: String, in window: NSWindow) throws {
        let field = try #require(
            subviewTree(of: window.contentView).compactMap { $0 as? NSTextField }.first {
                $0.placeholderString == CommentWording.searchPlaceholder
            }, "precondition: the search field")
        window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }
}
