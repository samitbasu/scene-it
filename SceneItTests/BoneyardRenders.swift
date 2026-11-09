import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// The Boneyard tray and the Scenes sheet's drags and keys (#29) in the window at 1× and 2×,
/// beside mockup 07: the recommended look (`final-*`) and the candidates the owner hasn't picked
/// between yet (`candidate-*`). In a `boneyard/` subfolder. A drag's states are drawn from the
/// sheet's own drop state, as the drop zones set it.
extension WindowRenders {
    @Test func boneyard() async throws {
        let output = try #require(renderFolder).appending(path: "boneyard", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let recommended = WindowMetrics.Scenes.look
        defer { WindowMetrics.Scenes.look = recommended }

        @MainActor func state(
            _ book: AppOpenBook, _ store: AppBookStore, _ preferences: AppPreferences,
            _ model: ScenesSheetModel,
            _ name: String, _ caption: String, mode: WindowMode = .scenes
        ) async throws {
            let window = BookWindow(
                book: book, store: store, preferences: preferences,
                formatting: EditorFormatting(preferences: preferences), mode: .constant(mode), scenes: model)
            let renders = try await Self.render(window, in: KeyWindow.self)
            try Self.write(renders, name: name, caption: caption, to: output, beside: Self.scenesCardsMockup)
        }

        try await withSampleBook(Self.scenesSampleBook()) { store, book, preferences in
            let view = preferences.scenesView
            defer { preferences.showScenes(as: view) }
            preferences.showScenes(as: .cards)
            let model = ScenesSheetModel()
            let story = book.book.scenes.map(\.id)
            let brother = try #require(book.book.boneyard.first?.id)

            try await state(book, store, preferences, model, "final-tray", "The Boneyard tray, 2 scenes")

            model.drop.begin(.card(story[2]))
            model.drop.enter(.tray)
            try await state(
                book, store, preferences, model, "final-tray-lit",
                "Card 3 dragged over the tray: it lights red")
            WindowMetrics.Scenes.look.trayLight = .fillAndDashedOutline
            try await state(
                book, store, preferences, model, "candidate-tray-lit-dashed",
                "Candidate: the tray lit with a dashed outline")
            WindowMetrics.Scenes.look = recommended

            model.drop.begin(.tile(brother))
            model.drop.enter(.card(story[6]))
            try await state(
                book, store, preferences, model, "final-restore-here",
                "\u{201C}The brother\u{201D} dragged over card 7: the Restore here slot")
            WindowMetrics.Scenes.look.slot = .neutral
            try await state(
                book, store, preferences, model, "candidate-restore-here-neutral",
                "Candidate: a gray slot, like + New scene")
            WindowMetrics.Scenes.look = recommended

            model.drop.begin(.card(story[8]))
            model.drop.enter(.card(story[1]))
            try await state(
                book, store, preferences, model, "final-move-here",
                "Card 9 dragged over card 2: the Move here slot")
            model.drop.end()

            WindowMetrics.Scenes.look.restoreButton = .onHover
            try await state(
                book, store, preferences, model, "candidate-restore-on-hover",
                "Candidate: a tile's \u{21A9} only while the pointer is over it")
            WindowMetrics.Scenes.look = recommended

            model.focused = story[1]
            try await state(
                book, store, preferences, model, "final-card-focused",
                "Arrow keys: the focused card (2) has the focus ring")
            model.focused = nil

            book.select(brother)
            try await state(
                book, store, preferences, model, "final-tray-open-scene",
                "\u{201C}The brother\u{201D} open: its tile is outlined")
            try await state(
                book, store, preferences, model, "final-boneyard-scene-page",
                "A Boneyard scene open: \u{201C}Boneyard \u{203A}\u{201D} and the rail's B", mode: .page)

            preferences.showScenes(as: .lightTable)
            try await state(
                book, store, preferences, model, "final-tray-light-table", "Light table with the tray")
            preferences.showScenes(as: .cards)

            #expect(book.deleteFromBoneyard(brother))
            try await state(
                book, store, preferences, model, "final-deleted-open-scene-page",
                "The open scene deleted from the Boneyard: no scene open", mode: .page)
            let second = try #require(book.book.boneyard.first?.id)
            #expect(book.deleteFromBoneyard(second))
            try await state(book, store, preferences, model, "final-tray-empty", "An empty Boneyard")
        }

        try await withReadOnlyBook(Self.scenesSampleBook()) { store, book, preferences in
            let view = preferences.scenesView
            defer { preferences.showScenes(as: view) }
            preferences.showScenes(as: .cards)
            try await state(
                book, store, preferences, ScenesSheetModel(), "final-tray-read-only",
                "Read-only: tiles with no handle or \u{21A9}")
        }
    }
}
