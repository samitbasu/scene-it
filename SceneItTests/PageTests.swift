import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

private func views(in view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap(views)
}

private let noted = CommentID(rawValue: "01JC4K00000000000000000NTD")
private let tooEarly = Comment(
    id: noted, color: .purple, text: "Too early?",
    created: Timestamp(Date(timeIntervalSince1970: 1_700_000_000), in: .gmt))

/// A book on disk, opened through a test-host controller and shown in an offscreen window of
/// our own, with its page and title field found.
@MainActor
private struct Harness {
    let url: URL
    let store: AppBookStore
    let book: AppOpenBook
    let window: NSWindow
    let page: ManuscriptTextView
    let title: NSTextField

    var storage: NSTextStorage { page.textStorage! }

    func body(_ scene: SceneID? = nil) -> [Paragraph] {
        book.book.scene(scene ?? book.openScene)?.body ?? []
    }

    /// Whether the page shows the open scene's body exactly as the codec renders it.
    var pageMirrorsModel: Bool {
        storage.isEqual(to: RunCodec.attributedString(forBody: body()))
    }

    func focusPage(at location: Int) {
        window.makeFirstResponder(page)
        page.setSelectedRange(NSRange(location: location, length: 0))
    }

    /// A pasteboard of our own, so no test touches the writer's clipboard.
    static func withPasteboard(_ body: (NSPasteboard) async throws -> Void) async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SceneItTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try await body(pasteboard)
    }
}

/// `scenes` in a book written to a temporary folder, then opened and shown.
@MainActor
private func withPage(
    _ scenes: [BookScene], holdingTheLock: Bool = false, _ body: (Harness) async throws -> Void
) async throws {
    try await withTemporaryFolder { folder in
        let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
        let books = BookController(role: .testHost)
        let store = books.store
        let holder: EditableBook?
        if holdingTheLock {
            holder = try BookPackage.create(at: url, title: "Novel")
            _ = try holder?.package.save(Book(title: "Novel", scenes: scenes))
            #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
        } else {
            holder = nil
            #expect(await store.create(at: url) == .created)
            #expect(await store.closeBook() == .left)
            try BookFormat.serialize(Book(title: "Novel", scenes: scenes)).write(
                to: url.appending(path: "book.md"), options: .atomic)
            #expect(await store.open(url) == .opened)
        }
        let book = try #require(store.current)

        let size = WindowMetrics.defaultSize
        let controller = NSHostingController(
            rootView: BookWindow(
                book: book, store: store, preferences: books.preferences, mode: .constant(.page)))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setFrame(NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), display: false)
        window.orderFront(nil)
        defer { window.close() }

        await eventually { views(in: window.contentView).contains { $0 is ManuscriptTextView } }
        let page = try #require(views(in: window.contentView).compactMap { $0 as? ManuscriptTextView }.first)
        let title = try #require(
            views(in: window.contentView).compactMap { $0 as? NSTextField }.first {
                $0.placeholderString == WindowWording.untitledScene
            })
        let harness = Harness(url: url, store: store, book: book, window: window, page: page, title: title)
        await eventually { harness.pageMirrorsModel }
        try await body(harness)
        #expect(await store.closeBook() == .left)
        withExtendedLifetime(holder) {}
    }
}

private enum Commented {
    case no, withTooEarly
}

private func scene(_ title: SceneTitle, _ body: [Paragraph] = [], _ commented: Commented = .no) -> BookScene {
    var ids = IDGenerator.system
    return BookScene(
        id: ids.sceneID(), modified: Timestamp(.now, in: .current), title: title, body: body,
        comments: commented == .withTooEarly ? [tooEarly] : [])
}

/// The commented, colored span the comment tests cut, copy and type beside.
private let letterScene: [Paragraph] = [
    [Run("The "), Run("letter", color: .red, comments: [noted]), Run(" waited.")],
    [Run("Dawn.")],
]

@Suite(.serialized, .timeLimit(.minutes(2)))
struct PageTests {
    @Test func thePageIsATextKit2TextViewWithTheBodyStyle() async throws {
        try await withPage([scene("One", [[Run("Hello.")]])]) { page in
            #expect(page.page.textLayoutManager != nil, "TextKit 2")
            #expect(page.page.isContinuousSpellCheckingEnabled)
            #expect(page.page.usesFindBar)
            #expect(!page.page.importsGraphics)
            let attributes = page.storage.attributes(at: 0, effectiveRange: nil)
            let style = try #require(attributes[.paragraphStyle] as? NSParagraphStyle)
            #expect(style.lineHeightMultiple == 2)
            #expect(style.firstLineHeadIndent == 36)
            #expect((attributes[.font] as? NSFont)?.familyName == ParagraphRole.fontFamily)
            #expect((attributes[.font] as? NSFont)?.pointSize == 12)
            let column = try #require(page.page.textContainer?.size.width)
            #expect(column == WindowMetrics.pageSize.width - 2 * WindowMetrics.pageMargin, "a 6.5 in column")
            #expect(page.page.pageRect.width == WindowMetrics.pageSize.width)
            #expect(page.page.pageRect.height >= WindowMetrics.pageSize.height)
        }
    }

    @Test func typingReachesTheModelInTheSameTurnAndBookMdThroughAutosave() async throws {
        try await withPage([scene("One")]) { page in
            await eventually { page.book.status == .saved }
            page.focusPage(at: 0)
            page.page.insertText("The ferry left.", replacementRange: page.page.selectedRange())
            #expect(page.body() == [[Run("The ferry left.")]])
            #expect(page.book.status == .unsaved, "autosave heard of the edit in the same turn")
            page.page.insertParagraphSeparator(nil)
            page.page.insertText("At dawn.", replacementRange: page.page.selectedRange())
            #expect(page.body() == [[Run("The ferry left.")], [Run("At dawn.")]])
            let open = try #require(page.book.openScene)
            #expect(page.book.wordCounts[open] == WordCount(words: 5))
            await eventually { page.book.status == .saved }
            let saved = try bookOnDisk(page.url)
            #expect(saved.scenes.first?.body == page.body())
        }
    }

    @Test func typedTextFollowsTheCharacterPolicyOnThePageAsInTheModel() async throws {
        try await withPage([scene("One", [[Run("ab")]])]) { page in
            page.focusPage(at: 1)
            page.page.insertText(
                "\u{201C}\u{2014}\u{1F30A}\u{201D}", replacementRange: page.page.selectedRange())
            #expect(page.body() == [[Run("a\"--[?]\"b")]])
            #expect(page.storage.string == "a\"--[?]\"b")
            #expect(
                page.page.selectedRange() == NSRange(location: 8, length: 0),
                "the caret follows the admitted text")
            #expect(page.pageMirrorsModel)
        }
    }

    @Test func pastedTextFollowsTheCharacterPolicy() async throws {
        try await withPage([scene("One")]) { page in
            try await Harness.withPasteboard { pasteboard in
                let pasted =
                    "\u{201C}It\u{2019}s\u{201D} \u{2014} \u{1F30A} \u{03A9}\u{03BC}\u{03AD}\u{03B3}\u{03B1}"
                pasteboard.clearContents()
                pasteboard.setString(pasted, forType: .string)
                page.focusPage(at: 0)
                #expect(page.page.readSelection(from: pasteboard))
                #expect(page.body() == [[Run("\"It's\" -- [?] [?][?][?][?][?]")]])
                #expect(page.pageMirrorsModel)
            }
        }
    }

    @Test func aPastedImageNeverReachesTheModel() async throws {
        try await withPage([scene("One")]) { page in
            try await Harness.withPasteboard { pasteboard in
                let image = NSImage(size: NSSize(width: 8, height: 8))
                image.lockFocus()
                NSColor.red.setFill()
                NSRect(x: 0, y: 0, width: 8, height: 8).fill()
                image.unlockFocus()
                let attachment = NSTextAttachment()
                attachment.image = image
                let rich = NSMutableAttributedString(string: "Before ")
                rich.append(NSAttributedString(attachment: attachment))
                rich.append(NSAttributedString(string: " after"))
                let rtfd = try #require(
                    rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
                #expect(rtfd.count > 0)
                pasteboard.clearContents()
                pasteboard.setData(rtfd, forType: .rtfd)
                #expect(
                    pasteboard.availableType(from: PageEditor.readableTypes) == .rtfd,
                    "precondition: only RTFD")

                page.focusPage(at: 0)
                #expect(page.page.readSelection(from: pasteboard))
                #expect(page.body() == [[Run("Before  after")]])
                #expect(!page.storage.string.contains("\u{FFFC}"))
                var attachments = 0
                page.storage.enumerateAttribute(
                    .attachment, in: NSRange(location: 0, length: page.storage.length)
                ) { value, _, _ in
                    if value != nil { attachments += 1 }
                }
                #expect(attachments == 0)
            }
        }
    }

    @Test func pastedRichTextKeepsOnlyTheStylesTheModelHolds() async throws {
        try await withPage([scene("One")]) { page in
            try await Harness.withPasteboard { pasteboard in
                let helvetica = try #require(NSFont(name: "Helvetica", size: 20))
                let bold = NSFontManager.shared.convert(helvetica, toHaveTrait: .boldFontMask)
                let foreign = NSMutableAttributedString(
                    string: "Plain ", attributes: [.font: helvetica, .foregroundColor: NSColor.orange])
                foreign.append(
                    NSAttributedString(
                        string: "bold\u{2028}next",
                        attributes: [.font: bold, .underlineStyle: NSUnderlineStyle.single.rawValue]))
                foreign.append(NSAttributedString(string: "\nlast", attributes: [.font: helvetica]))
                let rtf = try #require(
                    foreign.rtf(from: NSRange(location: 0, length: foreign.length), documentAttributes: [:]))
                pasteboard.clearContents()
                pasteboard.setData(rtf, forType: .rtf)
                pasteboard.setString(foreign.string, forType: .string)

                page.focusPage(at: 0)
                #expect(page.page.readSelection(from: pasteboard))
                #expect(
                    page.body() == [
                        [Run("Plain "), Run("bold", styles: [.bold])], [Run("next", styles: [.bold])],
                        [Run("last")],
                    ])
                #expect(page.pageMirrorsModel, "no foreign font, color or underline is left on the page")
            }
        }
    }

    @Test func cutAndPasteWithinASceneKeepsRunsAndCommentIds() async throws {
        try await withPage([scene("One", letterScene, .withTooEarly)]) { page in
            let before = page.body()
            try await Harness.withPasteboard { pasteboard in
                let letter = NSRange(location: 4, length: 6)
                #expect((page.storage.string as NSString).substring(with: letter) == "letter", "precondition")
                page.window.makeFirstResponder(page.page)
                page.page.setSelectedRange(letter)
                #expect(page.page.writeSelection(to: pasteboard, types: page.page.writablePasteboardTypes))
                #expect(pasteboard.types?.contains(.pageClip) == true)
                #expect(pasteboard.types?.contains(.rtf) == true)
                #expect(pasteboard.string(forType: .string) == "letter")
                page.page.delete(nil)
                #expect(page.body().first == [Run("The  waited.")])

                page.page.setSelectedRange(NSRange(location: 4, length: 0))
                #expect(page.page.readSelection(from: pasteboard))
                #expect(page.body() == before)
                #expect(page.book.book.scene(page.book.openScene)?.comments == [tooEarly])
                #expect(page.pageMirrorsModel)
            }
            await eventually { page.book.status == .saved }
            #expect(try bookOnDisk(page.url).scenes.first?.body == before)
        }
    }

    @Test func pastingIntoAnotherSceneCopiesTheCommentWithAFreshId() async throws {
        let source = scene("One", letterScene, .withTooEarly)
        let destination = scene("Two", [[Run("Elsewhere.")]])
        try await withPage([source, destination]) { page in
            try await Harness.withPasteboard { pasteboard in
                page.window.makeFirstResponder(page.page)
                page.page.setSelectedRange(NSRange(location: 4, length: 6))
                #expect(page.page.writeSelection(to: pasteboard, types: page.page.writablePasteboardTypes))

                page.book.select(destination.id)
                await eventually { page.storage.string == "Elsewhere." }
                page.focusPage(at: 0)
                #expect(page.page.readSelection(from: pasteboard))
                let pasted = try #require(page.book.book.scene(destination.id))
                let copy = try #require(pasted.comments.first)
                #expect(pasted.comments.count == 1)
                #expect(copy.id != noted)
                #expect(copy.text == tooEarly.text)
                #expect(
                    pasted.body == [[Run("letter", color: .red, comments: [copy.id]), Run("Elsewhere.")]])
                #expect(page.book.book.scene(source.id)?.comments == [tooEarly], "the source is untouched")

                let undo = try #require(page.page.undoManager)
                #expect(undo.canUndo)
                undo.undo()
                #expect(page.book.book.scene(destination.id)?.body == [[Run("Elsewhere.")]])
                #expect(page.book.book.scene(destination.id)?.comments == [], "undo takes the copy away too")
                undo.redo()
                #expect(page.book.book.scene(destination.id) == pasted)
            }
            await eventually { page.book.status == .saved }
            #expect(try bookOnDisk(page.url).scene(destination.id)?.comments.map(\.id) != [noted])
            #expect(try bookOnDisk(page.url) == page.book.book)
        }
    }

    @Test func typingAtTheEdgeOfACommentedSpanDoesntExtendIt() async throws {
        try await withPage([scene("One", letterScene, .withTooEarly)]) { page in
            page.focusPage(at: 10)
            #expect(page.storage.attributes(at: 9, effectiveRange: nil)[.comments] != nil, "precondition")
            page.page.insertText("s", replacementRange: page.page.selectedRange())
            #expect(
                page.body().first == [
                    Run("The "), Run("letter", color: .red, comments: [noted]), Run("s", color: .red),
                    Run(" waited."),
                ])
            page.focusPage(at: 4)
            page.page.insertText("a ", replacementRange: page.page.selectedRange())
            #expect(page.body().first?.runs.first == Run("The a "))
        }
    }

    @Test func undoAndRedoUpdateTheModel() async throws {
        try await withPage([scene("One", [[Run("Start.")]])]) { page in
            page.focusPage(at: 6)
            page.page.insertText(" More.", replacementRange: page.page.selectedRange())
            #expect(page.body() == [[Run("Start. More.")]])
            page.page.breakUndoCoalescing()
            let undo = try #require(page.page.undoManager)
            #expect(
                undo === page.book.pageUndo(for: try #require(page.book.openScene)), "the scene's own manager"
            )
            #expect(undo.canUndo)
            #expect(page.page.tryToPerform(UndoRoute.undo.selector, with: nil), "the toolbar's route")
            #expect(page.body() == [[Run("Start.")]])
            #expect(page.book.status == .unsaved)
            #expect(page.page.tryToPerform(UndoRoute.redo.selector, with: nil))
            #expect(page.body() == [[Run("Start. More.")]])
        }
    }

    @Test func eachSceneKeepsItsUndoAcrossASwitch() async throws {
        let one = scene("One", [[Run("First.")]])
        let two = scene("Two", [[Run("Second.")]])
        try await withPage([one, two]) { page in
            page.focusPage(at: 6)
            page.page.insertText(" Typed.", replacementRange: page.page.selectedRange())
            page.page.breakUndoCoalescing()
            #expect(page.book.pageUndo(for: one.id).canUndo)

            page.book.select(two.id)
            await eventually { page.storage.string == "Second." }
            #expect(page.page.undoManager === page.book.pageUndo(for: two.id))
            #expect(page.page.undoManager?.canUndo == false)

            page.book.select(one.id)
            await eventually { page.storage.string == "First. Typed." }
            page.page.undoManager?.undo()
            #expect(page.body(one.id) == [[Run("First.")]])
            #expect(page.storage.string == "First.")
        }
    }

    @Test func switchingScenesRebuildsThePage() async throws {
        let one = scene("One", [[Run("First", styles: [.italic])]])
        let two = scene("Two", [[Run("Second", color: .blue)], []])
        try await withPage([one, two]) { page in
            #expect(page.storage.string == "First")
            page.book.select(two.id)
            await eventually { page.storage.string == "Second\n" }
            #expect(page.pageMirrorsModel)
            #expect(page.page.selectedRange() == NSRange(location: 0, length: 0))
        }
    }

    @Test func aBodyChangedFromElsewhereRebuildsThePageAndClearsItsUndo() async throws {
        try await withPage([scene("One", [[Run("Typed.")]])]) { page in
            page.focusPage(at: 6)
            page.page.insertText(" More.", replacementRange: page.page.selectedRange())
            #expect(page.page.undoManager?.canUndo == true, "precondition: there is typing to undo")
            let open = try #require(page.book.openScene)
            page.book.replaceBody(of: open, with: [[Run("Replaced", styles: [.bold])]])
            await eventually { page.storage.string == "Replaced" }
            #expect(page.pageMirrorsModel)
            #expect(page.page.undoManager?.canUndo == false, "the old typing no longer fits the text")
        }
    }

    @Test func aCommentIdTheSceneDoesntHaveNeverReachesTheModelAndLeavesThePage() async throws {
        try await withPage([scene("One", [[Run("Plain text.")]])]) { page in
            let unknown = NSSet(object: "01JC4K0000000000000UNKNOWN")
            page.storage.addAttribute(.comments, value: unknown, range: NSRange(location: 0, length: 5))
            #expect(page.body() == [[Run("Plain text.")]])
            await eventually { page.storage.attribute(.comments, at: 0, effectiveRange: nil) == nil }
            #expect(page.pageMirrorsModel)
        }
    }

    @Test func aReadOnlyBookRefusesEdits() async throws {
        try await withPage([scene("Held", [[Run("Kept.")]])], holdingTheLock: true) { page in
            #expect(!page.page.isEditable)
            #expect(!page.title.isEnabled)
            page.window.makeFirstResponder(page.page)
            page.page.insertText("Typed", replacementRange: NSRange(location: 0, length: 0))
            try await Harness.withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("Pasted", forType: .string)
                #expect(!page.page.readSelection(from: pasteboard))
            }
            #expect(page.body() == [[Run("Kept.")]])
            #expect(page.storage.string == "Kept.")
        }
    }

    @Test func returnOrTabInTheTitleGoesToTheStartOfTheBodyAndShiftTabComesBack() async throws {
        try await withPage([scene("One", [[Run("Body text.")]])]) { page in
            for command in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:))] {
                #expect(page.window.makeFirstResponder(page.title))
                let editor = try #require(page.title.currentEditor() as? NSTextView)
                #expect(editor.isContinuousSpellCheckingEnabled, "the title checks spelling")
                editor.doCommand(by: command)
                #expect(page.window.firstResponder === page.page)
                #expect(page.page.selectedRange() == NSRange(location: 0, length: 0))

                page.page.insertBacktab(nil)
                #expect(
                    page.title.currentEditor() != nil, "Shift-Tab at the body's start returns to the title")
            }
            page.focusPage(at: 3)
            page.page.insertBacktab(nil)
            #expect(page.window.firstResponder === page.page, "only at the very start")
        }
    }

    @Test func cmdFShowsTheFindBarOverThePage() async throws {
        try await withPage([scene("One", [[Run("Find me.")]])]) { page in
            let scrollView = try #require(page.page.enclosingScrollView)
            #expect(!scrollView.isFindBarVisible)
            let find = try #require(menuItem(titled: "Find…", in: NSApp.mainMenu))
            #expect(find.keyEquivalent == "f")
            #expect(find.keyEquivalentModifierMask == [.command])
            page.window.makeFirstResponder(page.page)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            page.page.performFindPanelAction(item)
            #expect(scrollView.isFindBarVisible)
        }
    }

    /// The cost the writer feels per keystroke in a long scene: the page's edit, its conversion
    /// and the model's update, all of which happen before `insertText` returns.
    @Test func aKeystrokeInATenThousandWordSceneIsCheap() async throws {
        let words = ["the", "ferry", "crossed", "grey", "water", "and", "Mara", "watched", "it", "go"]
        let long: [Paragraph] = (0..<100).map { index in
            [Run((0..<100).map { words[($0 + index) % words.count] }.joined(separator: " ") + ".")]
        }
        #expect(WordCount(long).words == 10_000, "precondition: 10,000 words")
        try await withPage([scene("Long", long)]) { page in
            page.focusPage(at: (page.storage.string as NSString).length / 2)
            let clock = ContinuousClock()
            let keystrokes = 100
            let elapsed = clock.measure {
                for _ in 0..<keystrokes {
                    page.page.insertText("x", replacementRange: page.page.selectedRange())
                }
            }
            let wholeBody = clock.measure { _ = RunCodec.body(from: page.storage) }
            let perKeystroke = elapsed / keystrokes
            print("PageTests: per keystroke \(perKeystroke); converting the whole body \(wholeBody)")
            #expect(WordCount(page.body()).words == 10_000)
            #expect(page.body() == RunCodec.body(from: page.storage), "the ranged edits added up to the page")
            #expect(perKeystroke < .milliseconds(50))
        }
    }
}
