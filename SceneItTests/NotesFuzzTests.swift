import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// Runs `body` from the run loop, as an event's handling runs, never inside a Swift task (see
/// `PageFuzzTests`).
@MainActor
private func inATurn(_ body: @escaping @MainActor () -> Void) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        RunLoop.main.perform {
            MainActor.assumeIsolated(body)
            done.resume()
        }
    }
}

private let tides: [Paragraph] = [[Run("Check the tides.")], [Run("Dawn in March?")]]

private func withNotes(
    _ title: SceneTitle, _ body: [Paragraph], notes: [Paragraph], _ commented: Commented = .no
) -> BookScene {
    var made = scene(title, body, commented)
    made.notes = notes
    return made
}

/// The undo histories outlive every view SwiftUI builds and takes away (the Notes tab when the
/// panel changes tab, the page while no scene is open), so the text views they record typing
/// against must too: each window keeps one page and one notes view for its life.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct EditorLifetimeTests {
    @Test func undoAfterTheNotesTabWasShownAgainUndoesTheTyping() async throws {
        let one = withNotes("One", [[Run("Body.")]], notes: tides)
        try await withPage([one]) { page in
            let first = try await page.showNotes()
            await inATurn {
                page.focusNotes(first, at: 0)
                first.insertText("X", replacementRange: first.selectedRange())
            }
            #expect(page.notes().first == [Run("XCheck the tides.")])
            page.preferences.showRightPanelTab(.comments)
            await eventually { page.notesView == nil }
            #expect(page.notes().first == [Run("XCheck the tides.")], "kept on the tab switch")
            #expect(page.window.firstResponder === page.page, "the focus went back to the page")

            let notes = try await page.showNotes()
            #expect(notes === first, "the same view, back in the tab")
            await inATurn { page.focusNotes(notes, at: 1) }
            let undo = try #require(notes.undoManager)
            #expect(undo.canUndo)
            await undoInAnEvent(undo)
            #expect(page.notes() == tides, "the typing undone in the model")
            #expect(page.notesMirrorModel(notes))
            #expect(page.body() == one.body)
            await undoInAnEvent(undo, .redo)
            #expect(page.notes().first == [Run("XCheck the tides.")])
            #expect(page.notesMirrorModel(notes))
        }
    }

    /// The crash the review found: the old view had gone on to show an empty scene, so the
    /// typing's undo read past the end of its text.
    @Test func undoAfterTheTabWasShownAgainFromAnEmptySceneUndoesTheTyping() async throws {
        let one = withNotes("One", [[Run("Body.")]], notes: tides)
        let three = withNotes("Three", [[Run("Third.")]], notes: [])
        try await withPage([one, three]) { page in
            let first = try await page.showNotes()
            await inATurn {
                page.focusNotes(first, at: 0)
                first.insertText("X", replacementRange: first.selectedRange())
            }
            page.book.select(three.id)
            await eventually { first.string.isEmpty }
            page.preferences.showRightPanelTab(.comments)
            await eventually { page.notesView == nil }
            page.book.select(one.id)
            let notes = try await page.showNotes()
            await inATurn { page.focusNotes(notes, at: 0) }
            let undo = try #require(notes.undoManager)
            #expect(undo === page.book.notesUndo(for: one.id))
            await undoInAnEvent(undo)
            #expect(page.notes() == tides)
            #expect(page.notesMirrorModel(notes))
        }
    }

    /// With no scene open the page leaves the window; the scenes' page histories still work
    /// when it comes back.
    @Test func undoOnThePageAfterAStretchWithNoSceneOpen() async throws {
        let one = scene("One", [[Run("Start.")]])
        try await withPage([one]) { page in
            await inATurn {
                page.focusPage(at: 6)
                page.page.insertText(" More.", replacementRange: page.page.selectedRange())
            }
            #expect(page.body() == [[Run("Start. More.")]])
            page.book.select(nil)
            await eventually { page.page.window == nil }
            page.book.select(one.id)
            await eventually { page.page.window === page.window && page.pageMirrorsModel }
            await inATurn { page.focusPage(at: 0) }
            let undo = try #require(page.page.undoManager)
            #expect(undo === page.book.pageUndo(for: one.id))
            await undoInAnEvent(undo)
            #expect(page.body() == [[Run("Start.")]])
            #expect(page.pageMirrorsModel)
        }
    }

    @Test func typingThenChangingTabInOneTurnKeepsTheTypingAndFormatsNothingStale() async throws {
        let one = withNotes("One", [[Run("Body.")]], notes: tides)
        try await withPage([one]) { page in
            let notes = try await page.showNotes()
            await inATurn {
                page.focusNotes(notes, at: 0)
                notes.insertText("Y", replacementRange: notes.selectedRange())
                notes.setSelectedRange(NSRange(location: 0, length: 5))
                page.preferences.showRightPanelTab(.errors)
            }
            await eventually { page.notesView == nil }
            #expect(page.notes().first == [Run("YCheck the tides.")])
            #expect(page.formatting.active?.part != .notes)
            page.window.makeFirstResponder(nil)
            page.formatting.perform(.toggle(.bold))
            #expect(page.notes().first == [Run("YCheck the tides.")], "no stale format")
            #expect(page.body() == one.body, "nor on the page")
            await eventually { page.book.status == .saved }
            #expect(try bookOnDisk(page.url) == page.book.book)
        }
    }

    /// A commented span from one scene's page pasted into another's notes brings no comment
    /// (ADR 0032), and one undo takes the text away.
    @Test func aCommentedPasteIntoAnotherScenesNotesBringsNoComment() async throws {
        let one = withNotes("One", letterScene, notes: [], .withTooEarly)
        let two = withNotes("Two", [[Run("Second.")]], notes: [[Run("See ")]])
        try await withPage([one, two]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                await inATurn {
                    page.window.makeFirstResponder(page.page)
                    page.page.setSelectedRange(NSRange(location: 4, length: 6))
                    _ = page.page.writeSelection(to: pasteboard, types: page.page.writablePasteboardTypes)
                }
                page.book.select(two.id)
                let notes = try await page.showNotes()
                await eventually { notes.string == "See " }
                await inATurn {
                    page.focusNotes(notes, at: 4)
                    _ = notes.readSelection(from: pasteboard)
                }
                let pasted = try #require(page.book.book.scene(two.id))
                #expect(pasted.notes == [[Run("See "), Run("letter", color: .red)]])
                #expect(pasted.comments.isEmpty)
                let undo = try #require(notes.undoManager)
                #expect(!page.book.pageUndo(for: two.id).canUndo)
                await undoInAnEvent(undo)
                let undone = try #require(page.book.book.scene(two.id))
                #expect(undone.notes == two.notes)
                #expect(undone.comments.isEmpty)
                await undoInAnEvent(undo, .redo)
                #expect(page.book.book.scene(two.id)?.notes == pasted.notes)
                #expect(page.book.book.scene(two.id)?.comments == [])
                #expect(page.book.book.scene(one.id)?.body == letterScene, "the source is untouched")
                await eventually { page.book.status == .saved }
                #expect(try bookOnDisk(page.url) == page.book.book)
            }
        }
    }

    /// Opening the same package again (as Open Anyway or Open Other Version do) makes a new
    /// `OpenBook` at the same root, swapped in by the store in one turn, with the window still
    /// up: the window, with its editors and undo router, is made anew for it, so typing reaches
    /// the book that's open, not the one it replaced. (Keyed on the package root, the window
    /// kept its editors, bound to the old book, and this test fails.)
    @Test func reopeningTheSameBookGivesTheWindowNewEditorsForTheNewBook() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Held.sceneit", directoryHint: .isDirectory)
            let kept = scene("Kept", [[Run("Start.")]])
            var holder: EditableBook? = try BookPackage.create(at: url, title: "Held")
            _ = try holder?.package.save(Book(title: "Held", scenes: [kept]))
            let books = BookController(role: .testHost)
            let store = books.store
            #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
            let readOnly = try #require(store.current)

            let size = WindowMetrics.defaultSize
            let controller = NSHostingController(rootView: MainWindow(books: books))
            controller.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setFrame(NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), display: false)
            window.orderFront(nil)
            defer { window.close() }
            @MainActor func page() -> ManuscriptTextView? {
                subviewTree(of: window.contentView).compactMap { $0 as? ManuscriptTextView }.first
            }
            await eventually { page()?.string == "Start." }
            let before = try #require(page())
            #expect(before.editor?.book === readOnly)
            #expect(!before.isEditable, "precondition: read-only")

            holder = nil
            #expect(await store.open(url) == .opened)
            let editable = try #require(store.current)
            #expect(editable !== readOnly, "precondition: a new OpenBook")
            #expect(editable.layout.root == readOnly.layout.root, "precondition: at the same root")
            await eventually { page().map { $0.editor?.book === editable && $0.isEditable } == true }
            let after = try #require(page())
            #expect(after !== before, "a new window's editors")
            #expect(before.window == nil, "the old book's page left with its window")
            #expect(before.editor?.book !== store.current, "and was never bound to the new book")

            await inATurn {
                window.makeFirstResponder(after)
                after.setSelectedRange(NSRange(location: 6, length: 0))
                after.insertText(" More.", replacementRange: after.selectedRange())
            }
            #expect(editable.book.scene(kept.id)?.body == [[Run("Start. More.")]])
            #expect(readOnly.book.scene(kept.id)?.body == [[Run("Start.")]])
            await eventually { editable.status == .saved }
            #expect(try bookOnDisk(url).scenes.first?.body == [[Run("Start. More.")]])
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func theNotesHaveNoInputMethod() async throws {
        try await withPage([withNotes("One", [[Run("B")]], notes: tides)]) { page in
            let notes = try await page.showNotes()
            #expect(notes.inputContext == nil)
        }
    }
}

/// How much the two-editor fuzz runs. The gate runs a little; `NOTES_FUZZ_SEEDS` and
/// `NOTES_FUZZ_STEPS` (through xcodebuild, `TEST_RUNNER_NOTES_FUZZ_SEEDS` and
/// `TEST_RUNNER_NOTES_FUZZ_STEPS`) run more.
nonisolated enum NotesFuzz {
    static let seeds: [UInt64] = Array(1...UInt64(setting("NOTES_FUZZ_SEEDS", default: 2)))
    static let steps = setting("NOTES_FUZZ_STEPS", default: 120)
    /// Each seed's limit: generous at a fifth of a second a step, and never under two minutes.
    static let minutes = max(2, steps / 300 + 1)

    private static func setting(_ name: String, default value: Int) -> Int {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init).map { max(1, $0) } ?? value
    }
}

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Random edits to the page and the notes of three scenes, with scene switches and tab
/// switches between them, through every path that changes their text: after each step both
/// views mirror the model, no scene the step didn't touch changed, and no comment id dangles.
@Suite(.serialized, .timeLimit(.minutes(NotesFuzz.minutes)))
struct NotesFuzzTests {
    private static let other = Comment(
        id: CommentID(rawValue: "01JC4K00000000000000000R87"), color: .blue, text: "Other",
        created: Timestamp(Date(timeIntervalSince1970: 1_700_000_100), in: .gmt))

    private static let typed = [
        "a", " b", "\n", "x\ny", "\u{2014}", "\u{00E9}", "\n### Notes\n", "\n## Chapter\n",
        "\n### Comments\n- c0-1 | x\n", "\n---\n",
    ]

    @Test(arguments: NotesFuzz.seeds)
    func randomEditsToThePageAndTheNotesKeepThemInStep(seed: UInt64) async throws {
        var one = withNotes(
            "One", letterScene,
            notes: [[Run("Note "), Run("tide", comments: [Self.other.id])], [Run("two")]],
            .withTooEarly)
        one.comments.append(Self.other)
        let two = withNotes("Two", [[Run("Second body.")]], notes: [[Run("Second notes.")]])
        let three = withNotes("Three", [[Run("Third.")]], notes: [])
        try await withPage([one, two, three]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                var random = SplitMix(state: seed)
                var log: [String] = []
                var failure: String?
                _ = try await page.showNotes()
                let ids = [one.id, two.id, three.id]

                @MainActor func fail(_ message: String) {
                    failure = message + "\n" + log.suffix(10).joined(separator: "\n")
                }
                @MainActor func check(_ step: Int) {
                    guard failure == nil else { return }
                    if !page.pageMirrorsModel {
                        return fail("step \(step): the page doesn't mirror the body")
                    }
                    if let notes = page.notesView, !page.notesMirrorModel(notes) {
                        return fail("step \(step): the notes don't mirror the model")
                    }
                    for id in ids {
                        guard let scene = page.book.book.scene(id) else { continue }
                        let used = Paragraph.commentIDs(in: scene.body + scene.notes)
                        if !used.isSubset(of: Set(scene.comments.map(\.id))) {
                            return fail("step \(step): a dangling comment id in \(scene.title.text)")
                        }
                    }
                }

                for step in 0..<NotesFuzz.steps {
                    let open = try #require(page.book.openScene)
                    let before = Dictionary(uniqueKeysWithValues: ids.map { ($0, page.book.book.scene($0)) })
                    let action = Int.random(in: 0..<20, using: &random)
                    var awaitedTab: RightPanelTab?
                    var awaitedScene: SceneID?
                    await inATurn {
                        let notesView = page.notesView
                        let inNotes = notesView != nil && Bool.random(using: &random)
                        let view: NSTextView = inNotes ? notesView! : page.page
                        let name = inNotes ? "notes" : "page"
                        let length = view.textStorage?.length ?? 0
                        let a = Int.random(in: 0...length, using: &random)
                        let b = Int.random(in: 0...length, using: &random)
                        let range =
                            Bool.random(using: &random)
                            ? NSRange(location: a, length: 0)
                            : NSRange(location: min(a, b), length: abs(a - b))
                        func select() {
                            page.window.makeFirstResponder(view)
                            view.setSelectedRange(range)
                        }
                        switch action {
                        case 0, 1, 2:
                            select()
                            let text = Self.typed.randomElement(using: &random)!
                            log.append("\(step) \(name) type \(text.debugDescription) at \(range)")
                            view.insertText(text, replacementRange: view.selectedRange())
                        case 3:
                            select()
                            log.append("\(step) \(name) delete backward \(range)")
                            view.deleteBackward(nil)
                        case 4:
                            select()
                            log.append("\(step) \(name) copy \(range)")
                            pasteboard.clearContents()
                            _ = view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes)
                        case 5:
                            select()
                            log.append("\(step) \(name) cut \(range)")
                            if range.length > 0 {
                                pasteboard.clearContents()
                                _ = view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes)
                                view.delete(nil)
                            }
                        case 6, 7:
                            select()
                            log.append("\(step) \(name) paste at \(range)")
                            _ = view.readSelection(from: pasteboard)
                        case 8:
                            select()
                            let bold = NSFontManager.shared.convert(
                                NSFont.systemFont(ofSize: 12), toHaveTrait: .boldFontMask)
                            let rich = NSAttributedString(string: "R\u{2019}tf", attributes: [.font: bold])
                            pasteboard.clearContents()
                            pasteboard.setData(
                                rich.rtf(
                                    from: NSRange(location: 0, length: rich.length), documentAttributes: [:]),
                                forType: .rtf)
                            log.append("\(step) \(name) paste RTF at \(range)")
                            _ = view.readSelection(from: pasteboard)
                        case 9, 10:
                            page.window.makeFirstResponder(view)
                            view.breakUndoCoalescing()
                            log.append("\(step) \(name) undo")
                            if let undo = view.undoManager, undo.canUndo { undo.undo() }
                        case 11:
                            page.window.makeFirstResponder(view)
                            log.append("\(step) \(name) redo")
                            if let undo = view.undoManager, undo.canRedo { undo.redo() }
                        case 12, 13:
                            select()
                            let command = [
                                FormattingCommand.toggle(.bold), .toggle(.italic), .toggle(.strike),
                                .textColor(.red), .highlight(.green),
                            ].randomElement(using: &random)!
                            log.append("\(step) \(name) format \(command) \(range)")
                            page.formatting.perform(command)
                        case 14:
                            let target = ids.randomElement(using: &random)!
                            log.append("\(step) open scene \(ids.firstIndex(of: target)! + 1)")
                            page.book.select(target)
                            awaitedScene = target
                        case 15:
                            let tab: RightPanelTab =
                                notesView == nil
                                ? .notes : [.comments, .errors, .tags].randomElement(using: &random)!
                            log.append("\(step) tab \(tab)")
                            page.preferences.showRightPanelTab(tab)
                            awaitedTab = tab
                        case 16:
                            guard let notes = notesView else { return }
                            page.window.makeFirstResponder(notes)
                            notes.setSelectedRange(NSRange(location: 0, length: 0))
                            log.append("\(step) notes type Q, then another tab in the same turn")
                            notes.insertText("Q", replacementRange: notes.selectedRange())
                            page.preferences.showRightPanelTab(.comments)
                            awaitedTab = .comments
                        case 17:
                            guard let notes = notesView else { return }
                            page.window.makeFirstResponder(notes)
                            notes.setSelectedRange(NSRange(location: 0, length: 0))
                            let target = ids.first { $0 != open }!
                            log.append("\(step) notes type Z, then another scene in the same turn")
                            notes.insertText("Z", replacementRange: notes.selectedRange())
                            page.book.select(target)
                            awaitedScene = target
                        case 18:
                            log.append("\(step) focus the title")
                            page.window.makeFirstResponder(page.title)
                        default:
                            log.append("\(step) the router's undo")
                            if let router = try? page.undo { router.undo() }
                        }
                    }
                    if let tab = awaitedTab {
                        if tab == .notes {
                            await eventually { page.notesView.map(page.notesMirrorModel) == true }
                        } else {
                            await eventually { page.notesView == nil }
                        }
                    }
                    if let scene = awaitedScene {
                        await eventually { page.book.openScene == scene && page.pageMirrorsModel }
                    }
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        DispatchQueue.main.async { done.resume() }
                    }
                    check(step)
                    // Only the open scene changes, except where the step typed into it and then
                    // opened another.
                    if failure == nil, awaitedScene == nil {
                        for id in ids where id != open && page.book.book.scene(id) != before[id] ?? nil {
                            fail("step \(step): a scene that wasn't open changed")
                        }
                    }
                    if failure != nil { break }
                }
                #expect(failure == nil, "\(failure ?? "")")
                _ = try BookFormat.verifiedSerialization(of: page.book.book)
                page.store.saveNow()
                await eventually { page.book.status == .saved }
                #expect(try bookOnDisk(page.url) == page.book.book)
            }
        }
    }
}
