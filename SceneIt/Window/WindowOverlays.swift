import SceneItCore
import SwiftUI

/// What can be up over one book window's page: a rail sheet, File a Copy's dialog or Export as
/// SceneIt's chooser. Print… and Export to Word… start only while none is, from the menu and the
/// toolbar alike.
@MainActor
@Observable
final class WindowOverlays {
    private let filing: FilingFlow
    private let export: ExportFlow
    /// What the window shows over the book, kept up to date by the window.
    var mode = WindowMode.page

    init(filing: FilingFlow, export: ExportFlow) {
        self.filing = filing
        self.export = export
    }

    var noneUp: Bool {
        !mode.isSheet && filing.draft == nil && export.choice == nil
    }
}
