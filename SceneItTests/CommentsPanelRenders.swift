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
                menu: CommentID? = nil, _ prepare: @escaping (NSWindow) async throws -> Void
            ) async throws {
                let renders = try await Self.render(window(), withMenuOf: menu, preparing: prepare)
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

            @MainActor func selectPacked(_ window: NSWindow) throws {
                let page = try #require(Self.page(in: window))
                window.makeFirstResponder(page)
                page.setSelectedRange(
                    (page.string as NSString).range(of: "he had packed in the dark, by feel, the"))
            }

            try await state(
                "cards-selected", "Cards in text order; the letter's selected from the page", clickLetter)
            try await state(
                "comment-button", "Text selected on the page: the Comment button below it", selectPacked)

            let letter = CommentID(rawValue: "c1")
            let dream = CommentID(rawValue: "c5")
            for label in [CommentPanelCandidates.ColorLabel.capitalized, .lowercase] {
                CommentPanelCandidates.colorLabel = label
                try await state(
                    "menu-\(label)", "The \u{22EF} menu (\(label) names; stand-in drawing, see README)",
                    beside: Self.commentMenuMockup, menu: letter, clickLetter)
            }
            CommentPanelCandidates.colorLabel = .capitalized
            try await state(
                "menu-detached", "A detached card's \u{22EF} menu, text selected on the page",
                beside: Self.commentMenuMockup, menu: dream
            ) { window in
                try selectPacked(window)
                Self.editorOfPage(window)?.comments.select(dream, in: scene)
            }

            try await state("search-red-ferry", "#red ferry", beside: Self.commentSearchMockup) { window in
                try Self.typeInSearch("#red ferry", in: window)
            }
            try await state("search-unknown", "#mauve: an unknown color", beside: Self.commentSearchMockup) {
                window in
                try Self.typeInSearch("#mauve letter", in: window)
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
        }
    }

    private static func editorOfPage(_ window: NSWindow) -> SceneTextEditor? {
        page(in: window)?.editor
    }

    /// The panel and a little of the page, in the window's top-left points.
    static let panelRect = CGRect(x: 1440 - 420, y: 0, width: 420, height: 900)

    /// Like `render`, with the ⋯ menu of `comment`, if any, drawn where it would open.
    ///
    /// An open `NSMenu` is a modal tracking loop in a window of the system's, which no render can
    /// capture; so the menu is the card's real one, built by its ⋯ control, at its real size
    /// (`NSMenu.size`) and where the control would put it, and `MenuStandIn` draws its items:
    /// their titles (the colors' as attributed, line samples and all), check marks, separator,
    /// key equivalent and enabled state. The chrome, row heights and insets are approximations of
    /// macOS 26's menus, and there's no highlighted row.
    static func render(
        _ view: some View, withMenuOf comment: CommentID?, preparing prepare: (NSWindow) async throws -> Void
    ) async throws -> Renders {
        try await withWindow(view, in: KeyWindow.self, preparing: prepare) { window in
            let frameView = try #require(window.contentView?.superview)
            var standIn: (NSMenu, NSRect)?
            if let comment {
                let control = try #require(
                    subviewTree(of: window.contentView).compactMap { $0 as? CommentMenuButton.Control }.first
                    {
                        $0.comment == comment
                    }, "precondition: the card's \u{22EF} control shows")
                let menu = try #require(control.makeMenu?() ?? nil)
                let topLeft = control.convert(control.menuOrigin(menu), to: nil)
                let size = menu.size
                standIn = (
                    menu,
                    NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
                )
            }
            @MainActor func draw(_ scale: Int) -> NSBitmapImageRep {
                let rep = bitmap(of: frameView, scale: scale)
                guard let (menu, rect) = standIn else { return rep }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                MenuStandIn.draw(menu, in: rect)
                NSGraphicsContext.restoreGraphicsState()
                return rep
            }
            return Renders(single: draw(1), double: draw(2), triple: draw(3))
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

/// Draws an `NSMenu`'s items as macOS 26 shows an open menu, near enough for a look review.
enum MenuStandIn {
    static let padding: CGFloat = 5
    static let separatorHeight: CGFloat = 11
    static let checkColumn: CGFloat = 22
    static let trailingInset: CGFloat = 14

    static func draw(_ menu: NSMenu, in rect: NSRect) {
        let chrome = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        NSColor(white: 0.97, alpha: 1).setFill()
        chrome.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        chrome.stroke()

        let separators = CGFloat(menu.items.count { $0.isSeparatorItem })
        let rows = CGFloat(menu.items.count) - separators
        let rowHeight = (rect.height - 2 * padding - separators * separatorHeight) / rows
        let font = NSFont.menuFont(ofSize: 0)
        var top = rect.maxY - padding
        for item in menu.items {
            if item.isSeparatorItem {
                top -= separatorHeight
                NSColor.black.withAlphaComponent(0.1).setFill()
                NSRect(x: rect.minX + 12, y: top + separatorHeight / 2, width: rect.width - 24, height: 1)
                    .fill()
                continue
            }
            let row = NSRect(x: rect.minX, y: top - rowHeight, width: rect.width, height: rowHeight)
            top -= rowHeight
            let ink: NSColor = item.isEnabled ? .labelColor : .tertiaryLabelColor
            let title = NSMutableAttributedString(
                attributedString: item.attributedTitle
                    ?? NSAttributedString(string: item.title, attributes: [.font: font]))
            title.addAttribute(
                .foregroundColor, value: ink, range: NSRange(location: 0, length: title.length))
            let size = title.size()
            title.draw(at: NSPoint(x: row.minX + checkColumn, y: row.midY - size.height / 2))
            if item.state == .on {
                let check = NSAttributedString(
                    string: "\u{2713}",
                    attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: ink])
                check.draw(at: NSPoint(x: row.minX + 7, y: row.midY - check.size().height / 2))
            }
            if !item.keyEquivalent.isEmpty {
                let key = NSAttributedString(
                    string: item.keyEquivalent == "\u{8}" ? "\u{232B}" : item.keyEquivalent.uppercased(),
                    attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                key.draw(
                    at: NSPoint(
                        x: row.maxX - trailingInset - key.size().width, y: row.midY - key.size().height / 2))
            }
        }
    }
}
