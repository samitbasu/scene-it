import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// File a Copy as the owner chose it (#32): the dialog as a real sheet on the window at 1× and
/// 2× beside mockup 14, the sheet alone at 3×, and the toast.
extension WindowRenders {
    static let fileACopyMockup = "14-file-a-copy-dialog.png"

    private static func filledDraft() -> FilingDraft {
        var draft = FilingDraft(today: CalendarDay(year: 2026, month: 11, day: 1)!)
        for tag in ["draft 4", "before the ending"] {
            draft.pendingTag = tag
            draft.commitPendingTag()
        }
        draft.note = "Before the ending rewrite"
        return draft
    }

    @Test func fileACopy() async throws {
        let output = try #require(renderFolder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSampleBook { store, book, preferences in
            let filing = FilingFlow(book: book)
            filing.draft = Self.filledDraft()
            let dialog = BookWindow(
                book: book, store: store, preferences: preferences,
                formatting: EditorFormatting(preferences: preferences), mode: .constant(.page), filing: filing
            )
            let (renders, sheet) = try await Self.withWindow(dialog) { window in
                let sheet = try #require(window.attachedSheet, "precondition: the dialog is a sheet")
                let sheetView = try #require(sheet.contentView?.superview)
                return (try Self.withSheet(window, sheet), Self.bitmap(of: sheetView, scale: 3))
            }
            #expect(filing.draft != nil, "the dialog stayed up while it was drawn")
            filing.cancel()
            try Self.write(
                renders, name: "final-file-a-copy", caption: "File a copy", to: output,
                beside: Self.fileACopyMockup)
            try Self.png(sheet).write(to: output.appending(path: "final-file-a-copy-dialog@3x.png"))

            let long = FilingFlow(book: book)
            var draft = Self.filledDraft()
            draft.note = (1...6).map { "Line \($0) of a long note, which grows and then scrolls." }.joined(
                separator: "\n")
            long.draft = draft
            let longDialog = BookWindow(
                book: book, store: store, preferences: preferences,
                formatting: EditorFormatting(preferences: preferences), mode: .constant(.page), filing: long)
            let longSheet = try await Self.withWindow(longDialog) { window in
                let sheet = try #require(window.attachedSheet, "precondition: the dialog is a sheet")
                let note = try #require(
                    subviewTree(of: sheet.contentView).compactMap { $0 as? NSScrollView }
                        .first { $0.documentView is AdmittingTextView })
                let document = try #require(note.documentView)
                #expect(
                    document.frame.height > note.contentSize.height, "the note grew past its frame, to scroll"
                )
                return Self.bitmap(of: try #require(sheet.contentView?.superview), scale: 3)
            }
            try Self.png(longSheet).write(
                to: output.appending(path: "final-file-a-copy-long-note-dialog@3x.png"))
            long.cancel()

            let toasting = FilingFlow(book: book)
            let window = BookWindow(
                book: book, store: store, preferences: preferences,
                formatting: EditorFormatting(preferences: preferences), mode: .constant(.page),
                filing: toasting)
            let toast = try await Self.render(window) { _ in
                toasting.show(
                    ArchiveWording.toast(FilingRecord(filed: Self.filledDraft().filed, tags: ["draft 4"])))
            }
            #expect(toasting.toast != nil, "precondition: the toast is up")
            try Self.write(
                toast, name: "final-file-a-copy-toast", caption: "Filed: the toast", to: output,
                beside: Self.fileACopyMockup)
            try Self.png(Self.toastCloseUp(toast.triple)).write(
                to: output.appending(path: "final-file-a-copy-toast-close-up@3x.png"))
        }
    }

    /// The window with its sheet drawn where AppKit put it, with a shadow, at 1×, 2× and 3×.
    private static func withSheet(_ window: NSWindow, _ sheet: NSWindow) throws -> Renders {
        let frameView = try #require(window.contentView?.superview)
        let sheetView = try #require(sheet.contentView?.superview)
        let offset = NSPoint(
            x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY)
        func composite(_ scale: Int) throws -> NSBitmapImageRep {
            let base = bitmap(of: frameView, scale: scale)
            let top = bitmap(of: sheetView, scale: scale)
            let rep = blankBitmap(width: base.pixelsWide, height: base.pixelsHigh)
            rep.size = base.size
            let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            base.draw(in: NSRect(origin: .zero, size: base.size))
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.set()
            top.draw(in: NSRect(origin: offset, size: top.size))
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        return Renders(single: try composite(1), double: try composite(2), triple: try composite(3))
    }

    private static func toastCloseUp(_ rep: NSBitmapImageRep) throws -> NSBitmapImageRep {
        let image = try #require(rep.cgImage)
        let width: CGFloat = 700
        let height: CGFloat = 120
        let x = (windowSize.width - width) / 2
        let y = windowSize.height - height
        let crop = CGRect(x: x * 3, y: y * 3, width: width * 3, height: height * 3)
        return NSBitmapImageRep(cgImage: try #require(image.cropping(to: crop)))
    }
}
