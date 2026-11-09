import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// Read aloud (#39): ▶ dimmed with no selection, ▶ with one, and ■ while reading with the
/// sentence being read highlighted, as the whole window at 1× and 2× and the bar and the top of
/// the page close up at 2×. Nothing is heard: the window's synthesizer is a `RecordedSpeech`.
extension WindowRenders {
    @Test func readAloud() async throws {
        let output = try #require(renderFolder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSampleBook { store, book, preferences in
            let scene = try #require(book.openScene)
            book.replaceBody(of: scene, with: Self.formattedBody)
            let speech = RecordedSpeech()
            let readAloud = ReadAloud(preferences: preferences, speech: speech)
            let window = BookWindow(
                book: book, store: store, preferences: preferences,
                formatting: EditorFormatting(preferences: preferences), mode: .constant(.page),
                readAloud: readAloud)

            @MainActor func select(_ selection: Selection, in window: NSWindow) throws {
                let page = try #require(Self.page(in: window))
                #expect(window.makeFirstResponder(page))
                let text = page.string as NSString
                switch selection {
                case .caret:
                    page.setSelectedRange(NSRange(location: 0, length: 0))
                case .twoParagraphs:
                    let end = text.range(of: "ashore.")
                    try #require(end.location != NSNotFound, "precondition: the sample's second paragraph")
                    page.setSelectedRange(NSRange(location: 0, length: NSMaxRange(end)))
                }
            }

            let idle = try await Self.render(window, in: KeyWindow.self) { try select(.caret, in: $0) }
            #expect(readAloud.control == .unavailable, "precondition: ▶ dimmed")
            try Self.writeReadAloud(idle, name: "read-aloud-1-no-selection", to: output)

            let selected = try await Self.render(window, in: KeyWindow.self) {
                try select(.twoParagraphs, in: $0)
            }
            #expect(readAloud.control == .read, "precondition: ▶")
            try Self.writeReadAloud(selected, name: "read-aloud-2-selection", to: output)

            let reading = try await Self.render(window, in: KeyWindow.self) { window in
                try select(.twoParagraphs, in: window)
                readAloud.press()
                let utterance = try #require(speech.requests.last?.text) as NSString
                speech.report(.willSpeak(utterance.range(of: "deckhand")))
            }
            #expect(readAloud.control == .stop, "precondition: ■")
            try Self.writeReadAloud(reading, name: "read-aloud-3-reading", to: output)
            readAloud.stop()
        }
    }

    private enum Selection {
        case caret, twoParagraphs
    }

    private static func writeReadAloud(_ renders: Renders, name: String, to output: URL) throws {
        try png(renders.single).write(to: output.appending(path: "\(name)@1x.png"))
        try png(renders.double).write(to: output.appending(path: "\(name)@2x.png"))
        let image = try #require(renders.double.cgImage)
        let crop = CGRect(x: 0, y: 0, width: 1000 * 2, height: 480 * 2)
        try png(NSBitmapImageRep(cgImage: try #require(image.cropping(to: crop)))).write(
            to: output.appending(path: "\(name)-close-up@2x.png"))
    }
}
