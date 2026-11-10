import AppKit
import SceneItCore
import SwiftUI

/// Print… and Export to Word… for one book window, made together so both read the window's one
/// `OutputGate`. The window builds them and registers them with `MainWindowChrome` for the File
/// menu, so the menu and the toolbar act through the same flows.
@MainActor
final class WindowOutputs {
    let gate: OutputGate
    let printing: PrintFlow
    let wordExport: WordExportFlow

    init(
        book: AppOpenBook, store: AppBookStore, filing: FilingFlow, export: ExportFlow,
        wordDestination: @escaping () -> WordDestination
    ) {
        gate = OutputGate(book: book, store: store, filing: filing, export: export)
        printing = PrintFlow(gate: gate)
        wordExport = WordExportFlow(gate: gate, destination: wordDestination)
    }
}

/// Whether Print… or Export to Word… may start in one book window: the window still shows the
/// store's shown book, and nothing is up over its page, no rail sheet, File a Copy's dialog,
/// Export as SceneIt's chooser or the print dialog.
@MainActor
@Observable
final class OutputGate {
    let book: AppOpenBook
    let store: AppBookStore
    private let filing: FilingFlow
    private let export: ExportFlow
    /// What the window shows over the book, kept up to date by the window.
    var mode = WindowMode.page
    var printDialog = PrintDialog.closed
    /// The window, which Print…'s dialog is a sheet of.
    @ObservationIgnored weak var window: NSWindow?

    init(book: AppOpenBook, store: AppBookStore, filing: FilingFlow, export: ExportFlow) {
        self.book = book
        self.store = store
        self.filing = filing
        self.export = export
    }

    /// The book check matters between a session change (a filed copy showing over the book, say)
    /// and the new window registering its own outputs: until then the menu still reaches these.
    var isOpen: Bool {
        store.shown === book && !mode.isSheet && printDialog == .closed && filing.draft == nil
            && export.choice == nil
    }

    /// A sheet `isOpen` can't see, such as a print dialog left up by the window's previous view
    /// when the session changed under it. AppKit doesn't tell SwiftUI, so this is checked as an
    /// output starts, not for enablement.
    var windowHasSheet: Bool {
        window?.attachedSheet != nil
    }
}

enum PrintDialog {
    case open, closed
}
