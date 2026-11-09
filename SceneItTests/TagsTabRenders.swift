import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// The Tags tab (#20) as the owner picked its look, in the window at 100%, beside mockup 06: the
/// mockup's tags, a tag being typed, a scene with no tags, a long tag, many tags (scrolled to the
/// top and to the end), and a read-only book. In a `tags/` subfolder, each with a
/// `-panel@2x.png` close-up of the panel.
extension WindowRenders {
    static let tagsMockup = "06-tags-tab.png"

    /// The mockup's tags (06-tags-tab.png), one Boneyard scene among those that use them; the
    /// open scene (the ferry) has `opening` and `Mara`.
    static func taggedBook() -> Book {
        var book = sampleBook()
        let tags: [Int: [String]] = [
            0: ["opening", "Mara"], 1: ["Mara", "island"], 2: ["clue", "mother", "Mara"], 3: ["clue"],
            6: ["storm", "set piece"], 7: ["mother"],
        ]
        for (index, sceneTags) in tags { book.scenes[index].tags = sceneTags }
        book.boneyard[0].tags = ["Tomas", "clue"]
        return book
    }

    static let longTag = "the lighthouse keeper's second letter, the one she never opened"

    /// Forty-odd tags, used by from one to eight scenes.
    static func manyTaggedBook() -> Book {
        var book = taggedBook()
        let more = [
            "harbor", "lighthouse", "letter", "father", "school", "chapel", "fog", "debts", "salt", "radio",
            "night", "confession", "dream", "flashback", "foreshadowing", "winter", "keeper", "market",
            "tide",
            "map", "bell", "lantern", "return", "secret", "weather", "quiet", "turning point", "Ines",
            "Petra",
            "the brother", "mainland", "boat", "rain", "supper", "school bell", "inventory",
        ]
        for (index, tag) in more.enumerated() {
            for offset in 0...(index % 8) {
                let scene = (index + offset * 3) % book.scenes.count
                if !SceneTag.contains(book.scenes[scene].tags, tag) { book.scenes[scene].tags.append(tag) }
            }
        }
        return book
    }

    @Test func tagsTab() async throws {
        let output = try #require(renderFolder).appending(path: "tags", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        @MainActor func state(
            _ book: AppOpenBook, _ store: AppBookStore, _ preferences: AppPreferences, _ name: String,
            _ caption: String, _ prepare: @escaping (NSWindow) async throws -> Void = { _ in }
        ) async throws {
            let window = BookWindow(
                book: book, store: store, preferences: preferences,
                formatting: EditorFormatting(preferences: preferences), mode: .constant(.page))
            let renders = try await Self.render(window, in: KeyWindow.self, preparing: prepare)
            let file = "final-tags-\(name)"
            try Self.write(renders, name: file, caption: caption, to: output, beside: Self.tagsMockup)
            try Self.png(Self.closeUp(renders.double, Self.panelRect))
                .write(to: output.appending(path: "\(file)-panel@2x.png"))
        }

        try await withSampleBook(Self.taggedBook()) { store, book, preferences in
            preferences.reveal(.tags)
            defer { preferences.showRightPanelTab(.comments) }
            try await state(book, store, preferences, "mockup", "The mockup's tags")
            try await state(book, store, preferences, "typing", "Typing a tag") { window in
                let field = try #require(
                    subviewTree(of: window.contentView).compactMap { $0 as? AdmittingTextField }.first {
                        $0.placeholderString == TagWording.addPlaceholder
                    }, "precondition: the + tag field")
                window.makeFirstResponder(field)
                let editor = try #require(field.currentEditor() as? NSTextView)
                editor.insertText("isl", replacementRange: editor.selectedRange())
            }
            book.select(book.book.scenes[5].id)
            try await state(book, store, preferences, "no-tags-on-scene", "A scene with no tags")
            let ferry = try #require(book.book.scenes.first?.id)
            book.select(ferry)
            #expect(book.addTag(Self.longTag, to: ferry))
            try await state(
                book, store, preferences, "long-tag", "A long tag truncates; its tooltip has it all")
        }

        try await withSampleBook(Self.manyTaggedBook()) { store, book, preferences in
            preferences.reveal(.tags)
            defer { preferences.showRightPanelTab(.comments) }
            try #require(book.tags.entries.count > 30, "precondition: more tags than fit")
            try await state(book, store, preferences, "many-tags", "Many tags: the list scrolls")
            try await state(book, store, preferences, "many-tags-end", "Many tags, scrolled to the end") {
                window in
                let list = try #require(Self.tagsList(in: window), "precondition: the list")
                list.documentView?.scroll(NSPoint(x: 0, y: list.documentView?.bounds.maxY ?? 0))
            }
        }

        try await withReadOnlyBook(Self.taggedBook()) { store, book, preferences in
            preferences.reveal(.tags)
            defer { preferences.showRightPanelTab(.comments) }
            try await state(
                book, store, preferences, "read-only", "Read-only: no \u{00D7}, no + tag, rows not clickable")
        }
    }

    /// The Tags tab's list: SwiftUI's scroll view in the panel.
    static func tagsList(in window: NSWindow) -> NSScrollView? {
        subviewTree(of: window.contentView).compactMap { $0 as? NSScrollView }.first {
            !($0 is DeskView)
                && $0.convert($0.bounds, to: nil).minX >= window.frame.width - WindowMetrics.panelWidth - 1
        }
    }

    /// `sample` opened read-only, its lock held by another opening, as when it's open elsewhere.
    func withReadOnlyBook(
        _ sample: Book, _ body: (AppBookStore, AppOpenBook, AppPreferences) async throws -> Void
    ) async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let url = folder.appending(path: "My Novel.sceneit", directoryHint: .isDirectory)
            let holder = try BookPackage.create(at: url, title: sample.title)
            _ = try holder.package.save(sample)
            #expect(await books.store.open(url) == .openedReadOnly(.openElsewhere))
            try await body(books.store, try #require(books.store.current), books.preferences)
            #expect(await books.store.closeBook() == .left)
            withExtendedLifetime(holder) {}
        }
    }
}
