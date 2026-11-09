import AppKit
import SceneItCore
import SceneItTestSupport
import Testing
import WebKit

@testable import SceneIt

/// Copy Review and Save Review… in the app (ADR 0029, review format §5–§7): the File menu's items,
/// the clipboard's two representations, and the page Save Review… writes, from what the items run.
/// The test host's clipboard is a private pasteboard and its save panel names a file in the test's
/// own folder, so nothing here reaches the owner's clipboard or files.
extension OneAtATime.BookStoreIntegrationTests {
    @Test func theFileMenuHasCopyReviewAndSaveReviewAfterExport() throws {
        let copy = try #require(menuItem(titled: ReviewOutputWording.copyMenuItem, in: NSApp.mainMenu))
        let menu = try #require(copy.menu)
        let export = try #require(menuItem(titled: ExportWording.menuItem, in: menu))
        let save = try #require(menuItem(titled: ReviewOutputWording.saveMenuItem, in: menu))
        #expect(menu.index(of: copy) == menu.index(of: export) + 1)
        #expect(menu.index(of: save) == menu.index(of: copy) + 1)
        #expect(copy.keyEquivalent.isEmpty && save.keyEquivalent.isEmpty, "no shortcuts")
    }

    /// Copy Review in the File menu as it's drawn now; `nil` if it isn't there.
    @MainActor
    static func copyReviewIsEnabled() -> Bool? {
        OneBookRenders.fileMenu().items.first { $0.title == ReviewOutputWording.copyMenuItem }?.isEnabled
    }

    @Test func theTestHostsClipboardIsntTheOwners() {
        #expect(BookController.shared.reviewPasteboard.name != NSPasteboard.general.name)
    }

    @Test func copyReviewAndSaveReviewPutOutTheOpenReview() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.isChoosing, "precondition: the start screen")
            let copyURL = folder.appending(path: "Tide.md")
            try Data(ReviewOutputFixture.copy.utf8).write(to: copyURL)
            let copyBytes = try Data(contentsOf: copyURL)

            #expect(await store.openReview(copyURL) == .opened)
            let book = try #require(store.current)
            #expect(books.shareableReview == nil, "nothing to put out yet")
            await eventually { Self.copyReviewIsEnabled() == false }
            try ReviewOutputFixture.comment(book)
            #expect(books.shareableReview === book)
            await eventually { Self.copyReviewIsEnabled() == true }
            #expect(Self.copyReviewIsEnabled() == true)

            books.reviewPasteboard.clearContents()
            books.copyReview()

            let report = try #require(book.reviewReport(on: CalendarDay(.now, in: .current)))
            #expect(books.reviewPasteboard.string(forType: .html) == ReviewHTML.clipboard(report))
            #expect(books.reviewPasteboard.string(forType: .string) == ReviewPlainText.text(report))
            #expect(books.reviewPasteboard.string(forType: .string)?.contains("[harbor lights]") == true)

            let destination = folder.appending(path: "Tide review.html")
            books.reviewDestination = .fixed(destination)
            defer { books.reviewDestination = .nowhere }

            #expect(await books.saveReview() == .saved)

            guard case .review(let context) = book.document else {
                Issue.record("not a review")
                return
            }
            #expect(
                try String(contentsOf: destination, encoding: .ascii)
                    == ReviewHTML.page(report, review: context.id))
            #expect(try Data(contentsOf: copyURL) == copyBytes, "the copy is untouched")
            #expect(await store.closeBook() == .left)
            expectNoQuestions()
        }
    }
}

/// A review copy and a review to put out, shared by the tests and the renders.
enum ReviewOutputFixture {
    static let copy = """
        ---
        title: My Novel
        format: 2
        export: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
        exported: 2026-11-03T10:15:00-08:00
        ---

        ## The ferry
        id: s1
        modified: 2026-11-02T09:00:00-08:00

        The ferry left at dawn, and Mara watched the *harbor lights* go out one by one behind her.

        "Don't look back," the deckhand said -- and she didn't.

        ## Arrival
        id: s2
        modified: 2026-11-02T03:18:00-08:00

        Nobody met her at the landing, which she had half expected and wholly dreaded.

        At the top of the hill she stopped, set down the suitcase that had been her mother's, and \
        looked for a long time at the house... it had been painted **blue**.

        """

    /// Comments "harbor lights" in the first scene, through the page's own path.
    @MainActor
    static func comment(_ book: AppOpenBook) throws {
        let scene = SceneID(rawValue: "s1")
        let comment = try #require(book.newComment(in: scene, colored: .red))
        var first = try #require(book.book.scene(scene)?.body.first)
        first.runs = [
            Run("The ferry left at dawn, and Mara watched the "),
            Run("harbor lights", styles: [.italic], comments: [comment.id]),
            Run(" go out one by one behind her."),
        ]
        try #require(
            book.apply(BodyChange(lines: 0..<1, paragraphs: [first]), to: scene, adding: [comment]) != nil)
        book.setText("Lovely -- but is it too pretty for Mara's mood?", ofComment: comment.id, in: scene)
    }

    /// The worked example's report (review format §8), built from the parts the app makes.
    static func report() throws -> (ReviewReport, ReviewID) {
        let copy = try #require(
            ReceivedCopy(ReviewCopyFormat.parse(Data(Self.copy.utf8), opened: Timestamp(.now, in: .current))))
        let review = """
            ---
            title: My Novel
            format: 1
            copy: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
            id: 01JDD8WQ4K7M2N9P3R5S6T8V0X
            ---

            ### Notes
            Overall: I couldn't put it down. The *last line* of "Arrival" is the best thing here.

            ## The ferry
            id: s1

            ### Comments
            - c1 | red | 2026-11-04T09:12:00-08:00 | c45-58 | "harbor lights" | Lovely -- but is it too pretty for Mara's mood?
            - c2 | gray | 2026-11-04T09:30:00-08:00 | detached | The deckhand's line feels like a cliche. Cut it?

            ## Arrival
            id: s2

            ### Notes
            The arrival is *strong*. I'd keep the suitcase.

            ### Comments
            - c1 | blue | 2026-11-04T09:41:00-08:00 | c195-204 | "the house" | Which house? Remind us it's her mother's.

            """
        let parsed = ReviewFormat.parse(Data(review.utf8), against: copy) { ReviewID(rawValue: "unused") }
        try #require(parsed.newEntries.isEmpty, "precondition: the review reads cleanly")
        let report = ReviewReport(parsed.review, on: try #require(CalendarDay(year: 2026, month: 11, day: 4)))
        try #require(report.items.count == 3, "precondition: three items")
        return (report, parsed.review.id)
    }
}

/// Save Review…'s page in WebKit, as a browser shows it: it loads, has a checkbox for each item,
/// and remembers the ticked ones in the browser's storage. The web view's data store is
/// nonpersistent, so nothing is written to disk.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReviewPageWebTests {
    @Test func thePageLoadsWithACheckboxForEachItem() async throws {
        let (report, id) = try ReviewOutputFixture.report()
        let page = ReviewPage()
        try await page.load(ReviewHTML.page(report, review: id))

        #expect(try await page.number("document.querySelectorAll('input[type=checkbox]').length") == 3)
        #expect(try await page.number("document.querySelectorAll('input[data-item]').length") == 3)
        #expect(try await page.string("document.title") == "Review of My Novel")
        #expect(try await page.number("document.getElementById('no-storage').hidden ? 1 : 0") == 1)
        #expect(try await page.string("document.body.innerText")?.contains("[harbor lights]") == false)
    }

    @Test func aTickedBoxIsDimmedAndRememberedAcrossReloads() async throws {
        let (report, id) = try ReviewOutputFixture.report()
        let html = ReviewHTML.page(report, review: id)
        let page = ReviewPage()
        try await page.load(html)
        let item = try #require(report.items.last?.key.description)
        try #require(try await page.number("document.querySelectorAll('input:checked').length") == 0)

        _ = try await page.string("document.querySelector('input[data-item=\"\(item)\"]').click(); ''")

        let opacity =
            "document.querySelector('input[data-item=\"\(item)\"]').parentNode.parentNode.style.opacity"
        #expect(try await page.string(opacity) == "0.5")
        #expect(
            try await page.string("localStorage.getItem('sceneit.review.\(id)')") == "{\"\(item)\":true}")

        try await page.load(html)

        #expect(try await page.number("document.querySelectorAll('input:checked').length") == 1)
        #expect(
            try await page.number("document.querySelector('input[data-item=\"\(item)\"]').checked ? 1 : 0")
                == 1)
        #expect(try await page.string(opacity) == "0.5")
    }

    @Test func theSavedFileLoadsFromDisk() async throws {
        let (report, id) = try ReviewOutputFixture.report()
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "ReviewPage81-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "My Novel review.html")
        try Data(ReviewHTML.page(report, review: id).utf8).write(to: file)
        let page = ReviewPage()

        try await page.load(file: file)

        #expect(try await page.number("document.querySelectorAll('input[type=checkbox]').length") == 3)
        #expect(try await page.string("document.body.innerText")?.contains("Which house?") == true)
    }
}

/// A web view in an offscreen window, loading one page at a time.
@MainActor
final class ReviewPage: NSObject, WKNavigationDelegate {
    static let origin = URL(string: "https://review-81.invalid/")

    let view: WKWebView
    let window: NSWindow
    private var loading: CheckedContinuation<Void, any Error>?

    init(size: CGSize = CGSize(width: 900, height: 1100)) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init()
        view.navigationDelegate = self
        window.contentView = view
        window.orderBack(nil)
    }

    isolated deinit {
        window.orderOut(nil)
    }

    func load(_ html: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            view.loadHTMLString(html, baseURL: Self.origin)
        }
    }

    func load(file: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        }
    }

    func number(_ script: String) async throws -> Int? {
        (try await view.evaluateJavaScript(script) as? NSNumber)?.intValue
    }

    func string(_ script: String) async throws -> String? {
        try await view.evaluateJavaScript(script) as? String
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(error)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(error)
    }

    private func finish(_ error: (any Error)?) {
        let continuation = loading
        loading = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
}
