import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// File a Copy's candidates (#32): each dialog layout as a real sheet on the window at 1× and 2×
/// beside mockup 14, the sheet alone at 3×, and each toast placement.
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

    @Test func fileACopyCandidates() async throws {
        let output = try #require(renderFolder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSampleBook { store, book, preferences in
            for (letter, layout) in zip(["A", "B", "C"], FilingDialogLayout.allCases) {
                let filing = FilingFlow()
                filing.draft = Self.filledDraft()
                let window = BookWindow(
                    book: book, store: store, preferences: preferences,
                    formatting: PageFormatting(preferences: preferences), mode: .constant(.page),
                    filing: filing
                )
                .environment(\.filingDialogLayout, layout)
                let (renders, sheet) = try await Self.withWindow(window) { window in
                    let sheet = try #require(window.attachedSheet, "precondition: the dialog is a sheet")
                    let sheetView = try #require(sheet.contentView?.superview)
                    return (try Self.withSheet(window, sheet), Self.bitmap(of: sheetView, scale: 3))
                }
                let name = "candidate-\(letter)-\(layout)"
                try Self.write(
                    renders, name: name, caption: "Candidate \(letter): \(layout)", to: output,
                    beside: Self.fileACopyMockup)
                try Self.png(sheet).write(to: output.appending(path: "\(name)-dialog@3x.png"))
                #expect(filing.draft != nil, "the dialog stayed up while it was drawn")
            }
            for placement in FilingToastPlacement.allCases {
                let filing = FilingFlow()
                let window = BookWindow(
                    book: book, store: store, preferences: preferences,
                    formatting: PageFormatting(preferences: preferences), mode: .constant(.page),
                    filing: filing
                )
                .environment(\.filingToastPlacement, placement)
                let renders = try await Self.render(window) { _ in
                    filing.show(
                        ArchiveWording.toast(FilingRecord(filed: Self.filledDraft().filed, tags: ["draft 4"]))
                    )
                }
                #expect(filing.toast != nil, "precondition: the toast is up")
                let name = "toast-\(placement)"
                try Self.write(
                    renders, name: name, caption: "Toast: \(placement)", to: output,
                    beside: Self.fileACopyMockup)
                try Self.png(Self.toastCloseUp(renders.triple, placement)).write(
                    to: output.appending(path: "\(name)-close-up@3x.png"))
            }
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

    private static func toastCloseUp(_ rep: NSBitmapImageRep, _ placement: FilingToastPlacement) throws
        -> NSBitmapImageRep
    {
        let image = try #require(rep.cgImage)
        let width: CGFloat = 700
        let height: CGFloat = 120
        let x = (windowSize.width - width) / 2
        let y: CGFloat = placement == .bottom ? windowSize.height - height : 40
        let crop = CGRect(x: x * 3, y: y * 3, width: width * 3, height: height * 3)
        return NSBitmapImageRep(cgImage: try #require(image.cropping(to: crop)))
    }
}
