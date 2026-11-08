import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// Focus mode (#21) for the owner's pick: the window in normal mode, then in focus mode with
/// each candidate look, each beside normal mode.
extension WindowRenders {
    private struct FocusCandidate {
        let name: String
        let caption: String
        let rules: FocusModeRules
        let look: FocusModeLook
    }

    private static let focusCandidates: [FocusCandidate] = {
        let recommended = FocusModeRules.recommended
        var barHidden = recommended
        barHidden.formattingBar = .hidden
        return [
            FocusCandidate(
                name: "focus-a-hint",
                caption: "Focus mode A (recommended): \"Press Esc…\" hint, fades after 3 s",
                rules: recommended, look: FocusModeLook(desk: .unchanged, exit: .fadingHint)),
            FocusCandidate(
                name: "focus-b-no-cue", caption: "Focus mode B: no cue (View → Focus Mode or Esc)",
                rules: recommended, look: FocusModeLook(desk: .unchanged, exit: .none)),
            FocusCandidate(
                name: "focus-c-corner-button", caption: "Focus mode C: a faint corner button that leaves",
                rules: recommended, look: FocusModeLook(desk: .unchanged, exit: .cornerButton)),
            FocusCandidate(
                name: "focus-desk-dimmed", caption: "Focus mode, desk dimmed (with hint A)",
                rules: recommended, look: FocusModeLook(desk: .dimmed, exit: .fadingHint)),
            FocusCandidate(
                name: "focus-bar-hidden", caption: "Focus mode, formatting bar hidden too (with hint A)",
                rules: barHidden, look: FocusModeLook(desk: .unchanged, exit: .fadingHint)),
        ]
    }()

    @Test func focusMode() async throws {
        let output = try #require(renderFolder).appending(path: "focus-mode", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSampleBook { store, book, preferences in
            let scene = try #require(book.openScene)
            book.replaceBody(of: scene, with: Array(repeating: Self.formattedBody, count: 2).flatMap(\.self))
            let window = { (mode: WindowMode, chrome: WindowChrome) in
                BookWindow(
                    book: book, store: store, preferences: preferences,
                    formatting: EditorFormatting(preferences: preferences), mode: .constant(mode),
                    chrome: chrome)
            }
            let focusPage: (NSWindow) async throws -> Void = { window in
                let page = try #require(Self.page(in: window))
                #expect(window.makeFirstResponder(page))
                page.setSelectedRange(NSRange(location: 40, length: 0))
            }

            let normal = try await Self.render(window(.page, WindowChrome()), preparing: focusPage)
            try Self.writeFocus(normal, name: "normal", to: output)
            for candidate in Self.focusCandidates {
                let chrome = WindowChrome(rules: candidate.rules, look: candidate.look)
                chrome.set(.on)
                let renders = try await Self.render(window(.page, chrome), preparing: focusPage)
                try Self.writeFocus(renders, name: candidate.name, to: output)
                try Self.png(
                    try Self.composite(
                        renders.single, caption: candidate.caption, beside: Self.image(normal.single),
                        "Normal mode")
                ).write(to: output.appending(path: "\(candidate.name)-vs-normal.png"))
            }

            let searching = WindowChrome()
            searching.set(.on)
            let sheet = try await Self.render(window(.search, searching))
            try Self.writeFocus(sheet, name: "focus-search-sheet", to: output)

            preferences.setRightPanel(.closed)
            defer { preferences.setRightPanel(.open) }
            let collapsed = try await Self.render(window(.page, WindowChrome()), preparing: focusPage)
            try Self.writeFocus(collapsed, name: "normal-panel-collapsed", to: output)
        }
    }

    private static func writeFocus(_ renders: Renders, name: String, to folder: URL) throws {
        try png(renders.single).write(to: folder.appending(path: "\(name)@1x.png"))
        try png(renders.double).write(to: folder.appending(path: "\(name)@2x.png"))
    }

    private static func image(_ rep: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
