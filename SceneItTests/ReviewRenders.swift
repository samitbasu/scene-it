import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// Review Book…'s look (#80), chosen by default while the owner was away, into a `review/`
/// subfolder: the window over a review with its banner (A, shipped, in the read-only banner's
/// look) and two alternatives (B, a cool tint; C, no tint), each at 1× and 2× beside mockup 13
/// (the filed-copy banner the shipped one follows); and the start screen with Review Book… as a
/// third button (A, shipped) or on a line of its own (B). The alternatives are stand-ins laid
/// exactly over the shipped strip, so everything around them is the real window.
extension WindowRenders {
    static let readOnlyMockup = "13-read-only-filed-copy.png"

    @Test func reviewRenders() async throws {
        let output = try #require(renderFolder).appending(path: "review", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            let sample = Self.sampleBook()
            let copy = ReviewCopy(
                projecting: sample, chosen: Set(sample.scenes.prefix(6).map(\.id)),
                export: ExportID(rawValue: "01JDB2C7Q9X4M8T6V3N5R1K0PZ"),
                exported: Timestamp(.now, in: .current))
            let url = folder.appending(path: "My Novel.md")
            try ReviewCopyFormat.serialize(copy).write(to: url)
            #expect(await store.openReview(url) == .opened)
            let book = try #require(store.current)
            let scene = try #require(book.openScene)
            let comment = try #require(book.newComment(in: scene, colored: .red))
            let body = try #require(book.book.scene(scene)?.body)
            var first = body[0]
            first.runs = [
                Run("The ferry left at dawn, and Mara watched the "),
                Run("harbor lights", comments: [comment.id]),
                Run(" go out one by one behind her."),
            ]
            #expect(
                book.apply(BodyChange(lines: 0..<1, paragraphs: [first]), to: scene, adding: [comment]) != nil
            )
            book.setText("Too pretty for Mara's mood?", ofComment: comment.id, in: scene)
            books.preferences.showRightPanelTab(.comments)
            let window = BookWindow(
                book: book, store: store, preferences: books.preferences,
                formatting: EditorFormatting(preferences: books.preferences), mode: .constant(.page))

            try Self.write(
                try await Self.render(window), name: "review-a-banner",
                caption: "A (shipped): the read-only banner's look, a speech-bubble icon", to: output,
                beside: Self.readOnlyMockup)
            try Self.write(
                try await Self.render(
                    window.overlay(alignment: .top) { ReviewBannerCandidate(style: .tinted) }),
                name: "review-b-tinted", caption: "B: a cool tint, to tell a review from a warning",
                to: output, beside: Self.readOnlyMockup)
            try Self.write(
                try await Self.render(
                    window.overlay(alignment: .top) { ReviewBannerCandidate(style: .plain) }),
                name: "review-c-plain", caption: "C: no tint, the window's own background", to: output,
                beside: Self.readOnlyMockup)
            #expect(await store.closeBook() == .left)

            let start = BookController(role: .testHost)
            try Self.write(
                try await Self.render(MainWindow(books: start)), name: "start-a-third-button",
                caption: "A (shipped): Review Book… beside New and Open", to: output)
            try Self.write(
                try await Self.render(StartCandidate(books: start)), name: "start-b-own-line",
                caption: "B: Review Book… on a line of its own", to: output)
        }
    }
}

/// The shipped strip's layout with another background, drawn over it.
private struct ReviewBannerCandidate: View {
    enum Style {
        case tinted, plain
    }

    let style: Style

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                Text(ReviewWording.bannerTitle("My Novel")).fontWeight(.semibold)
                Text(ReviewWording.bannerDetail).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: WindowMetrics.bannerHeight)
            .background(background)
            Divider()
        }
    }

    private var background: Color {
        switch style {
        case .tinted: Color(red: 0.89, green: 0.93, blue: 0.99)
        case .plain: Color(nsColor: .windowBackgroundColor)
        }
    }
}

/// The start screen with Review Book… on a line of its own, under the recent books' heading.
private struct StartCandidate: View {
    let books: BookController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(WindowWording.noBookOpen)
                .font(.title2)
            HStack {
                Button(StoreWording.newBookMenuItem) {}
                Button(StoreWording.openBookMenuItem) {}
            }
            HStack(spacing: 6) {
                Text("Received a review copy?").foregroundStyle(.secondary)
                Button(ReviewWording.menuItem) {}.buttonStyle(.link)
            }
            Text(WindowWording.recentBooks)
                .font(.headline)
                .padding(.top, 8)
            Text(WindowWording.noRecentBooks)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(StoreWording.windowTitle)
    }
}

/// File → Review Book… on the start screen and with a book open, as the menu draws it.
extension OneAtATime.BookStoreIntegrationTests {
    @Test(.enabled(if: renderFolder != nil)) func reviewBookMenuRenders() async throws {
        let output = try #require(renderFolder).appending(path: "review", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(BookController.shared.store.isChoosing, "precondition: the start screen")
        await eventually { OneBookRenders.fileMenu().items.first?.isEnabled == true }
        try OneBookRenders.write(OneBookRenders.fileMenu(), name: "menu-review-book-start-screen", to: output)
    }
}
