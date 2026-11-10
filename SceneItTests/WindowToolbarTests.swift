import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// The toolbar in the app's own window (PLAN §4.1): its groups, and the zoom menu. SwiftUI's
/// toolbar controls can't be clicked here without input, so the zoom menu is chosen through the
/// menu AppKit shows for the item when it doesn't fit (its `menuFormRepresentation`), which
/// SwiftUI builds from the same `Menu`.
extension OneAtATime.BookStoreIntegrationTests {
    enum ToolbarSlot: Equatable {
        case item(String)
        case space
    }

    @MainActor
    static func toolbarSlots(_ window: NSWindow) -> [ToolbarSlot] {
        (window.toolbar?.items ?? []).map { item in
            item.itemIdentifier == .space ? .space : .item(item.menuFormRepresentation?.title ?? item.label)
        }
    }

    @MainActor
    static func zoomMenu(_ window: NSWindow) -> NSMenu? {
        window.toolbar?.items.lazy.compactMap { $0.menuFormRepresentation?.submenu }
            .first { $0.items.contains { $0.title == WindowWording.actualSize } }
    }

    /// Each group is a run of adjacent items, which share one glass capsule; two spaces part them.
    @Test func theToolbarGroupsUndoZoomOutputsAndFileACopy() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.isChoosing, "precondition: the start screen")
            try #require(
                books.preferences.zoom == .standard, "precondition: no other test left a zoom behind")
            let url = folder.appending(path: "Tide.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let window = try #require(books.mainWindow, "precondition: the app's main window")
            await eventually { window.toolbar?.isVisible == true && Self.toolbarSlots(window).count > 1 }

            let gap: [ToolbarSlot] = [.space, .space]
            let expected: [ToolbarSlot] =
                [.item(WindowWording.undo), .item(WindowWording.redo)] + gap
                + [.item(WindowWording.zoom(.standard))] + gap
                + [.item(WindowWording.print), .item(WindowWording.exportToWord)] + gap
                + [.item(WindowWording.fileACopy)]
            #expect(Array(Self.toolbarSlots(window).dropFirst()) == expected, "after the breadcrumb")

            #expect(await store.closeBook() == .left)
            expectNoQuestions()
        }
    }

    @Test func theToolbarsZoomMenuListsTheLadderAndSetsTheZoom() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            let preferences = books.preferences
            try #require(store.isChoosing, "precondition: the start screen")
            try #require(preferences.zoom == .standard, "precondition: no other test left a zoom behind")
            defer { preferences.setZoom(.standard) }
            let url = folder.appending(path: "Tide.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let window = try #require(books.mainWindow, "precondition: the app's main window")
            await eventually { window.toolbar?.isVisible == true && Self.zoomMenu(window) != nil }
            let menu = try #require(Self.zoomMenu(window), "precondition: the toolbar's zoom menu")

            let ladder = Zoom.steps.map(WindowWording.zoom)
            let commands = ZoomStep.allCases.map(WindowWording.zoomStep) + [WindowWording.actualSize]
            #expect(menu.items.map(\.title) == ladder + [""] + commands)
            #expect(menu.items[ladder.count].isSeparatorItem)
            #expect(
                menu.items.filter { $0.state == .on }.map(\.title) == [WindowWording.zoom(.standard)],
                "the current zoom is ticked")
            #expect(
                menu.items.allSatisfy { $0.keyEquivalent.isEmpty },
                "the View menu's items carry the shortcuts")

            @MainActor func choose(_ title: String) throws {
                let menu = try #require(Self.zoomMenu(window))
                try perform(try #require(menu.items.first { $0.title == title }, "\(title)"))
            }

            let chosen = Zoom(clamping: 1.5)
            try #require(Zoom.steps.contains(chosen), "precondition: 150% is on the ladder")
            try choose(WindowWording.zoom(chosen))
            #expect(preferences.zoom == chosen)
            await eventually { Self.zoomMenu(window)?.items.first { $0.state == .on }?.title == "150%" }
            #expect(Self.toolbarSlots(window).contains(.item("150%")), "the menu's title follows the zoom")

            try choose(WindowWording.zoomIn)
            #expect(preferences.zoom == Zoom(clamping: 1.75))
            try choose(WindowWording.zoomOut)
            try choose(WindowWording.zoomOut)
            #expect(preferences.zoom == Zoom(clamping: 1.25))
            try choose(WindowWording.actualSize)
            #expect(preferences.zoom == .standard)
            #expect(book.status == .saved, "zoom isn't part of the book (ADR 0022)")

            #expect(await store.closeBook() == .left)
            expectNoQuestions()
        }
    }
}
