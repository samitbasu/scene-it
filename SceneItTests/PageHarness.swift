import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// `view` and everything under it.
func subviewTree(of view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap(subviewTree)
}

let noted = CommentID(rawValue: "01JC4K00000000000000000NTD")
let tooEarly = Comment(
    id: noted, color: .purple, text: "Too early?",
    created: Timestamp(Date(timeIntervalSince1970: 1_700_000_000), in: .gmt))

/// A book on disk, opened through a test-host controller and shown in an offscreen window of
/// our own, with its page and title field found.
@MainActor
struct PageHarness {
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
func withPage(
    _ scenes: [BookScene], holdingTheLock: Bool = false, _ body: (PageHarness) async throws -> Void
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

        await eventually { subviewTree(of: window.contentView).contains { $0 is ManuscriptTextView } }
        let page = try #require(
            subviewTree(of: window.contentView).compactMap { $0 as? ManuscriptTextView }.first)
        let title = try #require(
            subviewTree(of: window.contentView).compactMap { $0 as? NSTextField }.first {
                $0.placeholderString == WindowWording.untitledScene
            })
        let harness = PageHarness(
            url: url, store: store, book: book, window: window, page: page, title: title)
        await eventually { harness.pageMirrorsModel }
        try await body(harness)
        #expect(await store.closeBook() == .left)
        withExtendedLifetime(holder) {}
    }
}

enum Commented {
    case no, withTooEarly
}

func scene(_ title: SceneTitle, _ body: [Paragraph] = [], _ commented: Commented = .no) -> BookScene {
    var ids = IDGenerator.system
    return BookScene(
        id: ids.sceneID(), modified: Timestamp(.now, in: .current), title: title, body: body,
        comments: commented == .withTooEarly ? [tooEarly] : [])
}

/// The commented, colored span the comment tests cut, copy and type beside.
let letterScene: [Paragraph] = [
    [Run("The "), Run("letter", color: .red, comments: [noted]), Run(" waited.")],
    [Run("Dawn.")],
]
