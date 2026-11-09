import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// The Scenes sheet (#28) in the window at 1× and 2×, beside mockups 07–09: the recommended look
/// (`final-scenes-*`) in each state, and the candidates the owner hasn't picked between yet
/// (`candidate-*`). In a `scenes/` subfolder.
extension WindowRenders {
    static let scenesCardsMockup = "07-scenes-cards-boneyard.png"
    static let scenesLightTableMockup = "08-scenes-light-table.png"
    static let scenesNewSceneMockup = "09-new-scene-inline-title.png"

    /// Mockup 07's first sentences and tags, and ages from "just now" to "2 months ago".
    static func scenesSampleBook(now: Date = .now) -> Book {
        var book = taggedBook()
        let sentences = [
            "The ferry left at dawn, and Mara watched the harbor lights go out one by one behind her.",
            "Nobody met her at the landing, which she had half expected and wholly dreaded.",
            "He read it twice before he understood that the handwriting was his mother's.",
            "By nine the square was loud with goats, gossip, and the smell of frying dough.",
            "Old Tomas kept the lamp lit long after the shipping lanes had moved north.",
            "They ate in silence, the bread already stale and the soup gone thin.",
            "The radio crackled twice and then gave up entirely.",
            "In the morning the beach was strewn with rope, glass, and one small shoe.",
            "Mara counted what she had: forty coins, a key, and no good reason to stay.",
            "This one was typed, which somehow made it worse.",
            "He wore his authority like a coat a size too large.",
            "There was no moon, only the slap of water and the captain's low cursing.",
            "Eleven children, one teacher, and a map that still showed the old border.",
            "Everyone on the island owed somebody something, and most of them owed Ilse.",
            "For three days the fog sat on the island like a held breath.",
            "It rang at noon on a Tuesday, though no one had climbed the tower in years.",
            "\"I didn't come back for the house,\" she said, and for once it was the truth.",
            "Her hands were raw from the brine, and still she kept working.",
            "The telephone in the post office rang for her at last.",
            "At low water you could walk to the rock, if you knew where to step.",
        ]
        let ages: [Interval] = [
            .zero, .hours(6), .hours(17), .hours(30), .days(2), .days(3), .days(5), .days(6), .days(8),
            .days(15), .days(16), .days(17), .days(22), .days(23), .days(29), .days(29), .days(35),
            .days(40), .days(45), .days(65),
        ]
        for index in book.scenes.indices {
            if sentences.indices.contains(index) {
                book.scenes[index].body = [[Run(sentences[index] + " Then the day went on as days do.")]]
            }
            let age = ages.indices.contains(index) ? ages[index] : .days(70)
            book.scenes[index].modified = Timestamp(now - age, in: .current)
        }
        book.scenes[0].body = [
            [Run(sentences[0])],
            [Run("She had packed in the dark, by feel, the way she used to as a girl.")],
        ]
        book.scenes[4].tags = ["Tomas"]
        book.scenes[8].tags = ["Mara"]
        book.scenes[9].tags = ["mother", "clue"]
        return book
    }

    @Test func scenesSheet() async throws {
        let output = try #require(renderFolder).appending(path: "scenes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let recommended = WindowMetrics.Scenes.look
        defer { WindowMetrics.Scenes.look = recommended }

        @MainActor func state(
            _ book: AppOpenBook, _ store: AppBookStore, _ preferences: AppPreferences,
            _ model: ScenesSheetModel,
            _ name: String, _ caption: String, beside mockup: String,
            _ prepare: @escaping (NSWindow) async throws -> Void = { _ in }
        ) async throws {
            let window = BookWindow(
                book: book, store: store, preferences: preferences,
                formatting: EditorFormatting(preferences: preferences), mode: .constant(.scenes),
                scenes: model)
            let renders = try await Self.render(window, in: KeyWindow.self, preparing: prepare)
            try Self.write(renders, name: name, caption: caption, to: output, beside: mockup)
        }

        try await withSampleBook(Self.scenesSampleBook()) { store, book, preferences in
            let view = preferences.scenesView
            defer { preferences.showScenes(as: view) }
            let model = ScenesSheetModel()
            preferences.showScenes(as: .cards)
            try await state(
                book, store, preferences, model, "final-scenes-cards", "Cards (recommended look)",
                beside: Self.scenesCardsMockup)
            try await state(
                book, store, preferences, model, "final-scenes-cards-tagging", "+ tag clicked on card 2",
                beside: Self.scenesCardsMockup
            ) { window in
                // As the chip's click does, once the render has cleared the focus, which closes it.
                model.field = .tagging(book.book.scenes[1].id)
                await eventually { Self.newTagField(in: window)?.currentEditor() != nil }
                let field = try #require(Self.newTagField(in: window), "precondition: the card's field")
                let editor = try #require(
                    field.currentEditor() as? NSTextView, "precondition: it took the focus")
                editor.insertText("harb", replacementRange: editor.selectedRange())
            }
            model.field = nil
            model.filter = "Mara"
            try await state(
                book, store, preferences, model, "final-scenes-filter", "Filter: Mara (title, text and tags)",
                beside: Self.scenesCardsMockup)
            model.filter = "lighthouse keeper's ghost"
            try await state(
                book, store, preferences, model, "final-scenes-no-matches", "Filter with no matches",
                beside: Self.scenesCardsMockup)
            WindowMetrics.Scenes.look.messages = .plain
            try await state(
                book, store, preferences, model, "candidate-messages-plain-no-matches",
                "Candidate: no-matches line without the hint", beside: Self.scenesCardsMockup)
            WindowMetrics.Scenes.look = recommended
            model.filter = ""
            WindowMetrics.Scenes.look.tagEntry = .alwaysField
            try await state(
                book, store, preferences, model, "candidate-tag-always-field",
                "Candidate: the Tags tab's + tag field on every card", beside: Self.scenesCardsMockup)
            WindowMetrics.Scenes.look = recommended

            preferences.showScenes(as: .lightTable)
            try await state(
                book, store, preferences, model, "final-scenes-light-table", "Light table (recommended look)",
                beside: Self.scenesLightTableMockup)
            let added = try #require(book.addScene(after: nil))
            book.select(book.book.scenes.first?.id)
            try await state(
                book, store, preferences, model, "final-scenes-new-scene-title",
                "The dashed tile added scene 25: typing its title", beside: Self.scenesNewSceneMockup
            ) { window in
                // As the tile does, once the render has cleared the focus, which accepts the title.
                model.field = .titling(added)
                await eventually { Self.cardTitleField(in: window)?.currentEditor() != nil }
                let field = try #require(Self.cardTitleField(in: window), "precondition: the title field")
                let editor = try #require(
                    field.currentEditor() as? NSTextView, "precondition: it took the focus")
                editor.insertText("The new scene title", replacementRange: editor.selectedRange())
            }
            model.close()
        }

        try await withReadOnlyBook(Self.scenesSampleBook()) { store, book, preferences in
            let view = preferences.scenesView
            defer { preferences.showScenes(as: view) }
            preferences.showScenes(as: .cards)
            try await state(
                book, store, preferences, ScenesSheetModel(), "final-scenes-read-only",
                "Read-only: no + New scene, no tile, no \u{00D7} or + tag", beside: Self.scenesCardsMockup)
        }

        try await withSampleBook(Book(title: "My Novel")) { store, book, preferences in
            let view = preferences.scenesView
            defer { preferences.showScenes(as: view) }
            preferences.showScenes(as: .cards)
            let model = ScenesSheetModel()
            try await state(
                book, store, preferences, model, "final-scenes-empty", "A book with no scenes",
                beside: Self.scenesCardsMockup)
            WindowMetrics.Scenes.look.messages = .plain
            try await state(
                book, store, preferences, model, "candidate-messages-plain-empty",
                "Candidate: no-scenes line without the hint", beside: Self.scenesCardsMockup)
            WindowMetrics.Scenes.look = recommended
        }
    }

    /// A card's + tag field, the only one in the sheet.
    static func newTagField(in window: NSWindow) -> AdmittingTextField? {
        subviewTree(of: window.contentView).compactMap { $0 as? AdmittingTextField }.first {
            $0.placeholderString == TagWording.addPlaceholder
        }
    }

    /// The title field on the card of a scene just added.
    static func cardTitleField(in window: NSWindow) -> AdmittingTextField? {
        subviewTree(of: window.contentView).compactMap { $0 as? AdmittingTextField }.first {
            $0.accessibilityLabel() == ScenesWording.titleLabel
        }
    }
}
