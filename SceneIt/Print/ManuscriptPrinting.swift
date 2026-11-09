import AppKit
import SceneItCore

/// Print… (PLAN §10.1), from the File menu and the toolbar: the standard print dialog, with
/// Scene It's choices as its accessory, over the book's window. It prints the book as it's shown,
/// saved or not, read-only or a filed copy.
enum ManuscriptPrinting {
    /// Whether `book` has anything to print: an open scene, or a scene in the manuscript.
    static func canPrint(_ book: AppOpenBook) -> Bool {
        book.book.scene(book.openScene) != nil || !book.book.scenes.isEmpty
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

    /// Shows the print dialog as a sheet on the book's window; nothing without one.
    static func run(_ book: AppOpenBook) {
        guard canPrint(book), let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        operation(for: book).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}
