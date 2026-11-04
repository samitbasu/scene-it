import AppKit
import SceneItCore
import Testing

@testable import SceneIt

/// A drag over one of our windows, as AppKit hands it to the view under the pointer: what it
/// carries, where it is, where it came from and what its source allows.
final class DragDouble: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingSource: Any?
    let draggingSourceOperationMask: NSDragOperation

    init(
        _ pasteboard: NSPasteboard, at location: NSPoint, in window: NSWindow?, from source: Any?,
        allowing mask: NSDragOperation
    ) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingDestinationWindow = window
        draggingSource = source
        draggingSourceOperationMask = mask
    }

    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set {}
    }
    var animatesToDestination: Bool {
        get { false }
        set {}
    }
    var numberOfValidItemsForDrop: Int {
        get { 1 }
        set {}
    }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// What the source of a drag lets the destination do with it.
enum DragSource {
    /// Another app, or a view that isn't the destination.
    case elsewhere
    /// The destination itself, moving its selection unless the writer holds Option.
    case moving(NSTextView)
    /// The destination itself, with Option held: a copy.
    case copying(NSTextView)

    var object: Any? {
        switch self {
        case .elsewhere: nil
        case .moving(let view), .copying(let view): view
        }
    }

    var mask: NSDragOperation {
        switch self {
        case .elsewhere, .moving: [.copy, .move, .generic]
        case .copying: .copy
        }
    }
}

/// What the view under the drag said to it.
struct DropOutcome {
    let entered: NSDragOperation
    let performed: Bool
}

/// Runs `body` from the run loop, as an event's handling runs, so an Objective-C exception in
/// AppKit stops the app there (ADR 0026) instead of unwinding through a Swift task.
@MainActor
func onTheRunLoop<T: Sendable>(_ body: @escaping @MainActor () -> T) async -> T {
    await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
        RunLoop.main.perform {
            done.resume(returning: MainActor.assumeIsolated(body))
        }
    }
}

extension NSTextView {
    /// The point, in the window, where a drop puts its text at `index`.
    func dropPoint(at index: Int) -> NSPoint {
        let caret = firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: nil)
        let rect = window?.convertFromScreen(caret) ?? caret
        return NSPoint(x: rect.minX + 0.5, y: rect.midY)
    }

    /// Drags what `pasteboard` holds over this view to `index` and drops it there, through the
    /// entry points AppKit calls; a drag the view refuses leaves it instead.
    func drop(_ pasteboard: NSPasteboard, at index: Int, from source: DragSource = .elsewhere) async
        -> DropOutcome
    {
        let point = dropPoint(at: index)
        #expect(
            characterIndexForInsertion(at: convert(point, from: nil)) == index, "precondition: the drop point"
        )
        return await onTheRunLoop { self.drop(pasteboard, atWindowPoint: point, from: source) }
    }

    /// `drop(_:at:from:)` at a point in the window, from the run loop already.
    func drop(_ pasteboard: NSPasteboard, atWindowPoint point: NSPoint, from source: DragSource)
        -> DropOutcome
    {
        let drag = DragDouble(pasteboard, at: point, in: window, from: source.object, allowing: source.mask)
        let entered = draggingEntered(drag)
        guard !entered.isEmpty, !draggingUpdated(drag).isEmpty, prepareForDragOperation(drag) else {
            draggingExited(drag)
            return DropOutcome(entered: entered, performed: false)
        }
        let performed = performDragOperation(drag)
        concludeDragOperation(drag)
        return DropOutcome(entered: entered, performed: performed)
    }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct DropTests {
    private static let rest = "Hello there."

    @Test func plainTextDropsWhereItsDroppedAsOneUndoableChange() async throws {
        try await withPage([scene("One", [[Run(Self.rest)]])]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("Dropped ", forType: .string)
                page.focusPage(at: 0)
                let undo = try #require(page.page.undoManager)
                endEvent(undo)
                let outcome = await page.page.drop(pasteboard, at: 6)
                #expect(outcome.entered.contains(.copy), "the page accepts a text drag")
                #expect(outcome.performed)
                #expect(page.body() == [[Run("Hello Dropped there.")]])
                #expect(
                    page.page.selectedRange() == NSRange(location: 6, length: 8),
                    "the dropped text is selected")
                #expect(page.pageMirrorsModel)
                undo.undo()
                #expect(page.body() == [[Run(Self.rest)]])
                #expect(!undo.canUndo, "one step")
            }
        }
    }

    @Test func droppedRichTextKeepsItsStylesAndBecomesASCII() async throws {
        try await withPage([scene("One", [[Run(Self.rest)]])]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                let bold = try #require(NSFont(name: "Helvetica-Bold", size: 14))
                let rich = NSMutableAttributedString(
                    string: "Caf\u{E9}", attributes: [.font: bold])
                rich.append(NSAttributedString(string: " \u{2014} \u{201C}na\u{EF}ve\u{201D} \u{1F30A} "))
                let rtf = try #require(
                    rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
                pasteboard.clearContents()
                pasteboard.setData(rtf, forType: .rtf)
                #expect(
                    pasteboard.availableType(from: SceneTextEditor.readableTypes) == .rtf, "precondition: RTF"
                )
                page.focusPage(at: 0)
                let outcome = await page.page.drop(pasteboard, at: 0)
                #expect(outcome.performed)
                #expect(
                    page.body() == [[Run("Cafe", styles: [.bold]), Run(" -- \"naive\" [?] " + Self.rest)]])
                #expect(page.storage.string.unicodeScalars.allSatisfy { $0.isASCII })
                #expect(page.pageMirrorsModel)
            }
        }
    }

    @Test func ourOwnClipDroppedInTheSameSceneKeepsItsComment() async throws {
        try await withPage([scene("One", letterScene, .withTooEarly)]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                page.focusPage(at: 0)
                page.page.setSelectedRange(NSRange(location: 4, length: 6))
                pasteboard.clearContents()
                #expect(page.page.writeSelection(to: pasteboard, types: page.page.writablePasteboardTypes))
                #expect(
                    pasteboard.availableType(from: SceneTextEditor.readableTypes) == .pageClip,
                    "precondition: our own clip")
                let end = page.storage.length
                let outcome = await page.page.drop(pasteboard, at: end)
                #expect(outcome.performed)
                #expect(
                    page.body() == [
                        letterScene[0], [Run("Dawn."), Run("letter", color: .red, comments: [noted])],
                    ])
                let scene = try #require(page.book.book.scene(page.book.openScene))
                #expect(scene.comments == [tooEarly], "the same comment, not a copy")
                #expect(page.pageMirrorsModel)
            }
        }
    }

    @Test func anImageIsRefused() async throws {
        try await withPage([scene("One", [[Run(Self.rest)]])]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                    NSColor.red.setFill()
                    rect.fill()
                    return true
                }
                let tiff = try #require(image.tiffRepresentation)
                let png = try #require(
                    NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                pasteboard.clearContents()
                pasteboard.setData(tiff, forType: .tiff)
                pasteboard.setData(png, forType: .png)
                #expect(pasteboard.types?.contains(.png) == true, "precondition: an image")
                #expect(
                    pasteboard.availableType(from: SceneTextEditor.readableTypes) == nil,
                    "precondition: no text")
                page.focusPage(at: 0)
                let outcome = await page.page.drop(pasteboard, at: 6)
                #expect(outcome.entered.isEmpty)
                #expect(!outcome.performed)
                #expect(page.body() == [[Run(Self.rest)]])
                #expect(page.storage.string == Self.rest)
            }
        }
    }

    @Test func aReadOnlyPageRefusesADrop() async throws {
        try await withPage([scene("Held", [[Run("Kept.")]])], holdingTheLock: true) { page in
            #expect(!page.page.isEditable, "precondition: read-only")
            try await PageHarness.withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("Dropped", forType: .string)
                let outcome = await page.page.drop(pasteboard, at: 2)
                #expect(outcome.entered.isEmpty)
                #expect(!outcome.performed)
                #expect(page.body() == [[Run("Kept.")]])
                #expect(page.storage.string == "Kept.")
            }
        }
    }

    /// Dragging a selection within the page moves it, comments and all, as one undoable step.
    @Test func draggingTheSelectionMovesItAsOneUndoableStep() async throws {
        try await withPage([scene("One", letterScene, .withTooEarly)]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                let undo = try #require(page.page.undoManager)
                let moved: [Paragraph] = [
                    [Run("The  waited.")], [Run("Dawn."), Run("letter", color: .red, comments: [noted])],
                ]
                page.focusPage(at: 0)
                page.page.setSelectedRange(NSRange(location: 4, length: 6))
                #expect(page.storage.attributedSubstring(from: page.page.selectedRange()).string == "letter")
                pasteboard.clearContents()
                #expect(page.page.writeSelection(to: pasteboard, types: page.page.writablePasteboardTypes))
                undo.removeAllActions()
                let outcome = await page.page.drop(
                    pasteboard, at: page.storage.length, from: .moving(page.page))
                #expect(outcome.performed)
                #expect(page.body() == moved, "moved forward")
                #expect(
                    page.page.selectedRange() == NSRange(location: 18, length: 6),
                    "the moved text is selected")
                let scene = try #require(page.book.book.scene(page.book.openScene))
                #expect(scene.comments == [tooEarly], "the comment kept its id")
                #expect(page.pageMirrorsModel)

                undo.undo()
                #expect(page.body() == letterScene, "one undo puts it back")
                #expect(!undo.canUndo, "one step")
                #expect(page.pageMirrorsModel)
                undo.redo()
                #expect(page.body() == moved)
                #expect(page.pageMirrorsModel)

                page.page.setSelectedRange(NSRange(location: 13, length: 5))
                #expect(page.storage.attributedSubstring(from: page.page.selectedRange()).string == "Dawn.")
                pasteboard.clearContents()
                #expect(page.page.writeSelection(to: pasteboard, types: page.page.writablePasteboardTypes))
                endEvent(undo)
                let back = await page.page.drop(pasteboard, at: 0, from: .moving(page.page))
                #expect(back.performed)
                #expect(
                    page.body() == [
                        [Run("Dawn.The  waited.")], [Run("letter", color: .red, comments: [noted])],
                    ], "moved backward")
                #expect(page.page.selectedRange() == NSRange(location: 0, length: 5))
                #expect(page.pageMirrorsModel)
            }
        }
    }

    @Test func optionDraggingTheSelectionCopiesIt() async throws {
        try await withPage([scene("One", [[Run(Self.rest)]])]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                page.focusPage(at: 0)
                page.page.setSelectedRange(NSRange(location: 0, length: 6))
                pasteboard.clearContents()
                #expect(page.page.writeSelection(to: pasteboard, types: page.page.writablePasteboardTypes))
                let outcome = await page.page.drop(pasteboard, at: 12, from: .copying(page.page))
                #expect(outcome.performed)
                #expect(page.body() == [[Run("Hello there.Hello ")]])
                #expect(page.pageMirrorsModel)
            }
        }
    }

    @Test func droppingTheSelectionOntoItselfChangesNothing() async throws {
        try await withPage([scene("One", [[Run(Self.rest)]])]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                page.focusPage(at: 0)
                page.page.setSelectedRange(NSRange(location: 0, length: 6))
                pasteboard.clearContents()
                #expect(page.page.writeSelection(to: pasteboard, types: page.page.writablePasteboardTypes))
                let outcome = await page.page.drop(pasteboard, at: 3, from: .moving(page.page))
                #expect(!outcome.performed)
                #expect(page.body() == [[Run(Self.rest)]])
                #expect(page.page.selectedRange() == NSRange(location: 0, length: 6))
            }
        }
    }

    /// The drop caret is the system's (ADR 0034), so it shows; the selection stays as it was
    /// while the drag is over the page, and becomes the dropped text after.
    @Test func theDropCaretShowsAndTheSelectionFollowsTheDrop() async throws {
        try await withPage([scene("One", [[Run(Self.rest)]])], in: KeyWindow.self) { page in
            try await PageHarness.withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("Dropped ", forType: .string)
                page.focusPage(at: 0)
                page.page.setSelectedRange(NSRange(location: 0, length: 5))
                let bands = page.page.selectionBands
                #expect(!bands.isEmpty, "precondition: a selection shows")
                let caret = try #require(page.page.insertionPointColor.usingColorSpace(.sRGB))
                #expect(caret.alphaComponent > 0, "the drop caret has a colour")
                let drag = DragDouble(
                    pasteboard, at: page.page.dropPoint(at: 6), in: page.window, from: nil,
                    allowing: DragSource.elsewhere.mask)
                await onTheRunLoop {
                    #expect(!page.page.draggingEntered(drag).isEmpty)
                    #expect(!page.page.draggingUpdated(drag).isEmpty)
                }
                #expect(
                    page.page.selectedRange() == NSRange(location: 0, length: 5),
                    "the drag leaves the selection")
                #expect(page.page.selectionBands == bands)
                await onTheRunLoop {
                    #expect(page.page.prepareForDragOperation(drag))
                    #expect(page.page.performDragOperation(drag))
                    page.page.concludeDragOperation(drag)
                }
                #expect(page.page.selectedRange() == NSRange(location: 6, length: 8))
                #expect(!page.page.selectionBands.isEmpty)
                #expect(page.page.selectionBands != bands, "the bands follow the dropped text")
            }
        }
    }

    @Test func theNotesTakeADropAsThePageDoes() async throws {
        var one = scene("One", [[Run(Self.rest)]])
        one.notes = [[Run("Tides.")]]
        try await withPage([one]) { page in
            let notes = try await page.showNotes()
            try await PageHarness.withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("Caf\u{E9} ", forType: .string)
                page.focusNotes(notes, at: 0)
                let outcome = await notes.drop(pasteboard, at: 0)
                #expect(outcome.performed)
                #expect(page.notes() == [[Run("Cafe Tides.")]])
                #expect(page.notesMirrorModel(notes))
                #expect(page.body() == [[Run(Self.rest)]])
            }
        }
    }

    @Test func theTitleTakesADropThroughItsPolicy() async throws {
        try await withPage([scene("One", [[Run(Self.rest)]])]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("Caf\u{E9}\n\u{2014}", forType: .string)
                #expect(page.window.makeFirstResponder(page.title))
                let editor = try #require(page.title.currentEditor() as? AdmittingTextView)
                let outcome = await editor.drop(pasteboard, at: 3)
                #expect(!outcome.entered.isEmpty)
                let title = try #require(page.book.book.scene(page.book.openScene)?.title)
                #expect(title == SceneTitle(pasted: "One" + "Caf\u{E9}\n\u{2014}"))
                #expect(editor.string == title.text)
                #expect(editor.string.unicodeScalars.allSatisfy { $0.isASCII })
            }
        }
    }
}
