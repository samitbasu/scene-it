import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// Where TextKit 2 broke each paragraph into lines: each line's characters, per paragraph.
@MainActor
private func lineBreaks(of page: ManuscriptTextView) throws -> [[NSRange]] {
    let layout = try #require(page.textLayoutManager)
    layout.ensureLayout(for: layout.documentRange)
    var lines: [[NSRange]] = []
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) {
        lines.append($0.textLineFragments.map(\.characterRange))
        return true
    }
    return lines
}

@MainActor
private func settle(_ desk: DeskView, at zoom: Zoom) async {
    await eventually { abs(desk.magnification - Double(zoom)) < 0.0001 }
}

private let wrapping: [Paragraph] = (2...6).map { count in
    [
        Run(
            String(
                repeating: "The ferry left the harbour at dawn, and nobody on the quay looked up. ",
                count: count))
    ]
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct ZoomTests {
    @Test func zoomNeverChangesLineBreaks() async throws {
        try await withPage([scene("Long", wrapping)]) { page in
            let desk = try page.desk
            let atActualSize = try lineBreaks(of: page.page)
            try #require(
                atActualSize.count == wrapping.count, "precondition: one layout fragment per paragraph")
            try #require(atActualSize.allSatisfy { $0.count > 1 }, "precondition: every paragraph wraps")

            let zooms = [0.5, 3, 1.1].map(Zoom.init(clamping:)) + [desk.fitWidthZoom]
            for zoom in zooms {
                page.preferences.setZoom(zoom)
                await settle(desk, at: zoom)
                #expect(try lineBreaks(of: page.page) == atActualSize, "at \(Double(zoom))")
                #expect(
                    page.page.frame.width >= DeskView.deskWidth - 1,
                    "the page is never narrower than the sheet, to within a point")
                if desk.contentView.bounds.width > DeskView.deskWidth {
                    #expect(
                        abs(page.page.pageRect.midX - desk.contentView.bounds.midX) < 1,
                        "the sheet stays centred on the visible desk at \(Double(zoom))")
                }
            }

            page.preferences.setZoom(Zoom(clamping: 3))
            await settle(desk, at: Zoom(clamping: 3))
            #expect(
                desk.contentView.bounds.width < DeskView.deskWidth,
                "precondition: at 300% less than the sheet's width is visible, so a page that followed the visible width would rewrap"
            )
            page.preferences.setZoom(Zoom(clamping: 0.5))
            await settle(desk, at: Zoom(clamping: 0.5))
            #expect(
                desk.contentView.bounds.width > page.page.pageRect.width * 1.5,
                "precondition: and at 50% far more")
        }
    }

    /// For both scroller styles, with a scene longer than the desk, so a legacy vertical
    /// scroller shows.
    @Test func fitWidthFitsTheSheetAndItsDeskWithNoHorizontalScroller() async throws {
        let lines: [Paragraph] = (1...80).map { _ in [Run("Line of text for the page.")] }
        try await withPage([scene("Long", lines)]) { page in
            let desk = try page.desk
            for style in [NSScroller.Style.overlay, .legacy] {
                page.preferences.setZoom(.standard)
                await settle(desk, at: .standard)
                desk.scrollerStyle = style
                desk.tile()
                let fit = desk.fitWidthZoom
                try #require(fit > .standard, "precondition: the window is wider than the desk")
                page.preferences.setZoom(fit)
                await settle(desk, at: fit)
                desk.tile()
                #expect(abs(desk.contentView.bounds.width - DeskView.deskWidth) < 1, "\(style.rawValue)")
                #expect(
                    page.page.frame.width <= desk.contentView.bounds.width,
                    "nothing to scroll sideways, \(style.rawValue)")
                if style == .legacy {
                    // An overlay scroller is faded out rather than hidden, so only a legacy one says.
                    #expect(desk.horizontalScroller?.isHidden ?? true, "no horizontal scroller")
                }
            }
        }
    }

    @Test func theSavedZoomIsShownWhenThePageOpens() async throws {
        let books = BookController(role: .testHost)
        books.preferences.setZoom(Zoom(clamping: 1.5))
        try await withPage([scene("One", [[Run("Text.")]])], books: books) { page in
            await settle(try page.desk, at: Zoom(clamping: 1.5))
        }
    }

    @Test func aPinchIsClampedToTheRangeAndKeptWhenItEnds() async throws {
        try await withPage([scene("One", [[Run("Text.")]])]) { page in
            let desk = try page.desk
            #expect(desk.allowsMagnification)
            #expect(abs(desk.minMagnification - ZoomBounds.range.lowerBound) < 0.0001)
            #expect(abs(desk.maxMagnification - ZoomBounds.range.upperBound) < 0.0001)

            NotificationCenter.default.post(name: NSScrollView.willStartLiveMagnifyNotification, object: desk)
            desk.magnification = 7
            #expect(desk.magnification == 3, "AppKit holds a pinch to the desk's range")
            desk.show(.standard)
            #expect(desk.magnification == 3, "a pinch in progress isn't overridden")
            #expect(page.preferences.zoom == .standard, "nothing is kept until the pinch ends")
            NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: desk)
            #expect(page.preferences.zoom == Zoom(clamping: 3))
            #expect((page.preferences.storage as? TransientPreferenceStorage)?.values["zoom"] == "3.0")
        }
    }
}
