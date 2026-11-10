import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

let noted = CommentID(rawValue: "01JC4K00000000000000000NTD")
let tooEarly = Comment(
    id: noted, color: .purple, text: "Too early?",
    created: Timestamp(Date(timeIntervalSince1970: 1_700_000_000), in: .gmt))

@Observable
final class ModeBox {
    var mode = WindowMode.page
}

/// `BookWindow` with its mode in `box`, so a test can open a sheet as the rail would.
struct BookWindowWithMode: View {
    let book: AppOpenBook
    let store: AppBookStore
    let preferences: AppPreferences
    var formatting: EditorFormatting?
    @Bindable var box: ModeBox
    var search: SearchSheetModel?
    var scenes: ScenesSheetModel?
    var cabinet: FileCabinetModel?
    var chrome: WindowChrome?
    var readAloud: ReadAloud?
    var filing: FilingFlow?

    var body: some View {
        BookWindow(
            book: book, store: store, preferences: preferences,
            formatting: formatting ?? EditorFormatting(preferences: preferences), mode: $box.mode,
            filing: filing, search: search, scenes: scenes, cabinet: cabinet, chrome: chrome,
            readAloud: readAloud)
    }
}

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
    let formatting: EditorFormatting
    let readAloud: ReadAloud
    let preferences: AppPreferences
    let modes: ModeBox
    /// The window's Search sheet.
    let search: SearchSheetModel
    /// The window's Scenes sheet.
    let scenes: ScenesSheetModel
    /// The window's File Cabinet.
    let cabinet: FileCabinetModel
    /// The window's focus mode.
    let chrome: WindowChrome
    /// The window's File a Copy.
    let filing: FilingFlow
    /// Whether the editors keep the writer's automatic-change preferences or have them off.
    let automaticChanges: AutomaticChangesInTests

    /// Turns `view`'s automatic changes off, unless the test asked for the defaults: the test host
    /// is the real app, so the writer's own menu choices would otherwise reach every page test.
    func settle(_ view: NSTextView) {
        guard automaticChanges == .off else { return }
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
    }

    /// The window's undo router, as the toolbar uses it.
    var undo: UndoRouter {
        get throws {
            let routers = subviewTree(of: window.contentView).compactMap {
                ($0 as? UndoRouterWindow.WindowView)?.router
            }
            return try #require(routers.first)
        }
    }

    var desk: DeskView {
        get throws { try #require(page.enclosingScrollView as? DeskView) }
    }

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

/// A window that says it's key, so a test sees what only a key window shows, such as the caret,
/// without activating the app, which would take the keyboard from whatever the owner is using.
final class KeyWindow: NSWindow {
    nonisolated(unsafe) static var isKey = true

    override var isKeyWindow: Bool { Self.isKey }
}

/// Whether a page test's editors have the automatic text changes off, or as the defaults say.
enum AutomaticChangesInTests {
    case off, asTheDefaultsSay
}

/// Whether a test's book is opened with its lock, or while another opening holds it, so it
/// opens read-only.
enum TestBookLock {
    case ours, heldElsewhere
}

/// `scenes` in a book written to a temporary folder, then opened and shown in a window of
/// `windowType`.
@MainActor
func withPage(
    _ scenes: [BookScene], boneyard: [BookScene] = [], lock: TestBookLock = .ours,
    books: BookController = BookController(role: .testHost), in windowType: NSWindow.Type = NSWindow.self,
    searchIndexing: @escaping SearchSheetModel.Indexing = SearchSheetModel.keywordIndexing,
    scenesSheet: ScenesSheetModel = ScenesSheetModel(),
    cabinet: FileCabinetModel = FileCabinetModel(),
    filed: [FilingRecord] = [],
    automaticChanges: AutomaticChangesInTests = .off,
    _ body: (PageHarness) async throws -> Void
) async throws {
    try await withTemporaryFolder { folder in
        let textKit1 = failOnTextKit1()
        defer { NotificationCenter.default.removeObserver(textKit1) }
        let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
        let store = books.store
        let holder: EditableBook?
        let written = Book(title: "Novel", scenes: scenes, boneyard: boneyard)
        if lock == .heldElsewhere {
            holder = try BookPackage.create(at: url, title: "Novel")
            _ = try holder?.package.save(written)
            for record in filed { _ = try holder?.package.fileCopy(of: written, as: record) }
            #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
        } else {
            holder = nil
            #expect(await store.create(at: url) == .created)
            #expect(await store.closeBook() == .left)
            try BookFormat.serialize(written).write(to: url.appending(path: "book.md"), options: .atomic)
            if !filed.isEmpty {
                let filing = try #require(try BookPackage.open(at: url).editable, "precondition: filing")
                for record in filed { _ = try filing.package.fileCopy(of: written, as: record) }
            }
            #expect(await store.open(url) == .opened)
        }
        let book = try #require(store.current)

        let size = WindowMetrics.defaultSize
        let modes = ModeBox()
        let chrome = WindowChrome()
        let search = SearchSheetModel(book: book, indexing: searchIndexing)
        let filing = FilingFlow(book: book)
        let controller = NSHostingController(
            rootView: BookWindowWithMode(
                book: book, store: store, preferences: books.preferences, formatting: books.formatting,
                box: modes, search: search, scenes: scenesSheet, cabinet: cabinet, chrome: chrome,
                readAloud: books.readAloud, filing: filing))
        controller.sizingOptions = []
        let window = windowType.init(
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
            url: url, store: store, book: book, window: window, page: page, title: title,
            formatting: books.formatting, readAloud: books.readAloud, preferences: books.preferences,
            modes: modes, search: search, scenes: scenesSheet, cabinet: cabinet, chrome: chrome,
            filing: filing, automaticChanges: automaticChanges)
        harness.settle(page)
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
