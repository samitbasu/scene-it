import AppKit
import SceneItCore
import SwiftUI

/// Print… (PLAN §10.1) for one book window, from the File menu (through `MainWindowChrome`) and
/// the toolbar alike: the standard print dialog, with Scene It's choices as its accessory, as a
/// sheet on that window. It prints the book the window shows, saved or not, read-only or a filed
/// copy.
@Observable
final class PrintFlow: NSObject {
    private let gate: OutputGate

    /// How the dialog is shown: as a sheet, except in tests, which record it instead.
    static var present: @MainActor (NSPrintOperation, NSWindow, PrintFlow) -> Void = {
        operation, window, flow in
        operation.runModal(
            for: window, delegate: flow,
            didRun: #selector(PrintFlow.printOperationDidRun(_:success:contextInfo:)),
            contextInfo: nil)
    }

    init(gate: OutputGate) {
        self.gate = gate
    }

    var book: AppOpenBook {
        gate.book
    }

    var window: NSWindow? {
        gate.window
    }

    /// Whether Print… can start: the book has something to print, and the gate is open.
    var canBegin: Bool {
        ManuscriptPrinting.canPrint(book) && gate.isOpen
    }

    func begin() {
        guard canBegin, !gate.windowHasSheet, let window else { return }
        gate.printDialog = .open
        Self.present(ManuscriptPrinting.operation(for: book), window, self)
    }

    /// The dialog has gone, printed or canceled.
    @objc func printOperationDidRun(
        _ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        finished()
    }

    func finished() {
        gate.printDialog = .closed
    }
}

enum ManuscriptPrinting {
    /// Whether `book` has anything to print: an open scene, or a scene in the story.
    static func canPrint(_ book: AppOpenBook) -> Bool {
        !PrintRange.offered(in: book.book, open: book.openScene).isEmpty
    }

    /// The operation for `book` as it is now, its dialog set up but not run.
    static func operation(for book: AppOpenBook) -> NSPrintOperation {
        let choices = PrintChoices(openScene: book.openScene, in: book.book)
        let view = ManuscriptPrintView(book: book.book, openScene: book.openScene, choices: choices)
        let operation = NSPrintOperation(view: view, printInfo: printInfo(for: choices.layout))
        operation.jobTitle = PrintWording.jobTitle(
            book: book.book.title, scene: choices.range == .thisScene ? book.book.scene(book.openScene) : nil)
        let panel = operation.printPanel
        panel.options.formUnion([.showsPaperSize, .showsOrientation, .showsPreview])
        panel.addAccessoryController(PrintAccessoryController(choices: choices))
        return operation
    }

    /// A copy of the app's print settings with no margins, since each page draws its own, and
    /// the paper turned for `layout`.
    static func printInfo(for layout: PrintLayout) -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.orientation = NSPrintInfo.PaperOrientation(layout.orientation)
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }
}
