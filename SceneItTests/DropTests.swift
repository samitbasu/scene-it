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
    let draggingSourceOperationMask: NSDragOperation = [.copy, .move, .generic]

    init(_ pasteboard: NSPasteboard, at location: NSPoint, in window: NSWindow?, from source: Any?) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingDestinationWindow = window
        draggingSource = source
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

/// What can be dragged onto a text view: each kind on a pasteboard of its own.
enum Dragged: CaseIterable {
    case plainText, richText, pageClip, image, file

    /// Puts this kind on `pasteboard`.
    @MainActor
    func write(to pasteboard: NSPasteboard) throws {
        pasteboard.clearContents()
        switch self {
        case .plainText:
            pasteboard.setString("Dropped", forType: .string)
        case .richText:
            let rich = NSAttributedString(
                string: "Caf\u{E9}", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
            let rtf = try #require(
                rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
            pasteboard.setData(rtf, forType: .rtf)
        case .pageClip:
            let source = scene("Source", letterScene, .withTooEarly)
            let clip: Data = try #require(PageClip(letterScene, from: source).data)
            pasteboard.setData(clip, forType: .pageClip)
        case .image:
            let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                NSColor.red.setFill()
                rect.fill()
                return true
            }
            let tiff: Data = try #require(image.tiffRepresentation)
            pasteboard.setData(tiff, forType: .tiff)
        case .file:
            pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/notes.txt") as NSURL])
        }
        #expect(pasteboard.types?.isEmpty == false, "precondition: \(self) is on the pasteboard")
    }
}

/// Runs `body` from the run loop, as an event's handling runs, so an Objective-C exception in
/// AppKit doesn't unwind a Swift task. HIToolbox still swallows it, `done.resume()` never runs,
/// and the test hangs on the continuation until its time limit, but Swift concurrency is left
/// intact (ADR 0026).
@MainActor
func onTheRunLoop(_ body: @escaping @MainActor () -> Void) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        RunLoop.main.perform {
            MainActor.assumeIsolated(body)
            done.resume()
        }
    }
}

/// How a text view handles a press on macOS 27. An `NSTextView` that overrides `mouseDown`, as the page
/// does for comment clicks, tracks presses there, as before macOS 27; one that doesn't selects through
/// an `NSTextSelectionManager`, which asks its delegate for a drag of the selection.
enum PressRoute {
    case mouseDown, selectionManager
}

extension NSTextView {
    /// Drags each kind of content over this view at its first character, from elsewhere and from
    /// the view itself, through the entry points AppKit calls, and checks that each is refused,
    /// and that a drop forced on it anyway changes nothing.
    func expectRefusesEveryDrop() async throws {
        let before = try #require(textStorage?.copy() as? NSAttributedString)
        let point = convert(NSPoint(x: textContainerOrigin.x + 1, y: textContainerOrigin.y + 1), to: nil)
        try await PageHarness.withPasteboard { pasteboard in
            for kind in Dragged.allCases {
                try kind.write(to: pasteboard)
                for source in [nil, self as Any] {
                    let drag = DragDouble(pasteboard, at: point, in: window, from: source)
                    let from = source == nil ? "elsewhere" : "itself"
                    await onTheRunLoop {
                        #expect(self.draggingEntered(drag).isEmpty, "\(kind) from \(from) is refused")
                        #expect(self.draggingUpdated(drag).isEmpty, "\(kind) from \(from) is refused")
                        #expect(!self.performDragOperation(drag), "\(kind) from \(from) isn't dropped")
                        self.concludeDragOperation(drag)
                    }
                    #expect(textStorage?.isEqual(to: before) == true, "\(kind) from \(from) changed nothing")
                }
            }
        }
        #expect(acceptableDragTypes.isEmpty)
        #expect(registeredDraggedTypes.isEmpty, "the window routes no drag here")
    }

    /// Checks that this view refuses to start a drag of its selection, at the methods `NSTextView`
    /// starts one from. A refusal that's lost would start a real drag session, so each method is
    /// called only once it's known to be ours.
    func expectRefusesToDragItsSelection(pressedThrough route: PressRoute) throws {
        #expect(selectedRange().length > 0, "precondition: a selection to drag")
        let legacy = #selector(NSTextView.dragSelection(with:offset:slideBack:))
        try #require(
            method_getImplementation(try #require(class_getInstanceMethod(KeyboardTextView.self, legacy)))
                != method_getImplementation(try #require(class_getInstanceMethod(NSTextView.self, legacy))),
            "precondition: the press-and-drag method is overridden")
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDragged, location: convert(NSPoint(x: 5, y: 5), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 1,
                pressure: 1))
        #expect(!dragSelection(with: event, offset: .zero, slideBack: true), "no drag from mouseDown")
        if #available(macOS 27, *) {
            guard route == .selectionManager else {
                #expect(textSelectionManager == nil, "precondition: presses go through mouseDown")
                return
            }
            let manager = try #require(
                textSelectionManager, "precondition: presses go through a selection manager")
            #expect(manager.delegate === self, "precondition: the view is the manager's delegate")
            let session = NSSelectorFromString("selectionManager:makeDraggingSessionWithGesture:")
            try #require(
                class_getMethodImplementation(KeyboardTextView.self, session)
                    != class_getMethodImplementation(NSTextView.self, session),
                "precondition: the manager's drag request is answered here")
            let gesture = try #require(manager.gesturesForFailureRequirements.first)
            #expect(
                (self as? KeyboardTextView)?.selectionManager(manager, makeDraggingSession: gesture) == nil,
                "no drag from macOS 27")
        }
        #expect(selectedRange().length > 0, "the selection is still there")
    }
}

extension NSTextField {
    /// Checks that a drag over this field while it isn't being edited reaches nothing that takes
    /// it: AppKit sends a drag to the deepest view under the pointer registered for one of its
    /// types, and neither the field nor anything around it is.
    func expectRefusesDropsWhileNotEditing() async throws {
        #expect(currentEditor() == nil, "precondition: not being edited")
        #expect(isEditable, "precondition: an editable field")
        let before = stringValue
        var chain: [NSView] = []
        var view: NSView? = self
        while let next = view {
            chain.append(next)
            view = next.superview
        }
        try await PageHarness.withPasteboard { pasteboard in
            for kind in Dragged.allCases {
                try kind.write(to: pasteboard)
                let types = Set(pasteboard.types ?? [])
                let takers = chain.filter { !types.isDisjoint(with: $0.registeredDraggedTypes) }
                #expect(takers.isEmpty, "\(kind) reaches no view: \(takers.map { type(of: $0) })")
                let drag = DragDouble(
                    pasteboard, at: convert(NSPoint(x: 2, y: 2), to: nil), in: window, from: nil)
                await onTheRunLoop {
                    let destination = self as NSDraggingDestination
                    #expect(destination.draggingEntered?(drag).isEmpty ?? true, "\(kind) is refused")
                    #expect(!(destination.performDragOperation?(drag) ?? false), "\(kind) isn't dropped")
                }
                #expect(stringValue == before, "\(kind) changed nothing")
            }
        }
    }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct DropTests {
    @Test func theTitleFieldRefusesADropWhileNotBeingEdited() async throws {
        try await withPage([scene("One", [[Run("Hello there.")]])]) { page in
            page.focusPage(at: 0)
            try await page.title.expectRefusesDropsWhileNotEditing()
            #expect(page.book.book.scene(page.book.openScene)?.title == "One")
        }
    }

    @Test func thePageRefusesEveryDropAndNeverDragsItsSelection() async throws {
        try await withPage([scene("One", letterScene, .withTooEarly)]) { page in
            page.focusPage(at: 0)
            #expect(page.page.isEditable, "precondition: an editable page")
            try await page.page.expectRefusesEveryDrop()
            #expect(page.body() == letterScene)
            #expect(page.pageMirrorsModel)
            page.page.setSelectedRange(NSRange(location: 4, length: 6))
            try page.page.expectRefusesToDragItsSelection(pressedThrough: .mouseDown)
        }
    }

    @Test func theNotesRefuseEveryDropAndNeverDragTheirSelection() async throws {
        var one = scene("One", [[Run("Hello there.")]])
        one.notes = [[Run("Check the tides.")]]
        try await withPage([one]) { page in
            let notes = try await page.showNotes()
            page.focusNotes(notes, at: 0)
            try await notes.expectRefusesEveryDrop()
            #expect(page.notes() == [[Run("Check the tides.")]])
            #expect(page.notesMirrorModel(notes))
            notes.setSelectedRange(NSRange(location: 0, length: 5))
            try notes.expectRefusesToDragItsSelection(pressedThrough: .selectionManager)
        }
    }

    @Test func theTitleRefusesEveryDropAndNeverDragsItsSelection() async throws {
        try await withPage([scene("One", [[Run("Hello there.")]])]) { page in
            #expect(page.window.makeFirstResponder(page.title))
            let editor = try #require(
                page.title.currentEditor() as? AdmittingTextView, "the title's own editor")
            try await editor.expectRefusesEveryDrop()
            #expect(page.book.book.scene(page.book.openScene)?.title == "One")
            editor.setSelectedRange(NSRange(location: 0, length: 3))
            try editor.expectRefusesToDragItsSelection(pressedThrough: .selectionManager)
        }
    }

    @Test func aReadOnlyPageRefusesEveryDrop() async throws {
        try await withPage([scene("Held", [[Run("Kept.")]])], holdingTheLock: true) { page in
            #expect(!page.page.isEditable, "precondition: read-only")
            try await page.page.expectRefusesEveryDrop()
            #expect(page.body() == [[Run("Kept.")]])
        }
    }
}
