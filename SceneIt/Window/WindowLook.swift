import SceneItCore
import SwiftUI

// PROVISIONAL (#13, phase 1). The candidate looks the owner is choosing between, so each can be
// rendered beside the mockup. Once the owner picks, the window keeps only the chosen ones and
// this type goes away.

struct WindowLook: Hashable {
    enum RailIcons: CaseIterable {
        /// a1: closest to the mockup.
        case document
        /// a2: stacked drawers for the File Cabinet.
        case cabinet
        /// a3: text-centred symbols.
        case text
    }

    enum TitlePlacement: CaseIterable {
        /// b1: a labelled field in its own strip above the desk, aligned to the page's text column.
        case strip
        /// b2: in the editor control bar's row, after the formatting buttons.
        case controlBar
        /// b3: a large borderless field on the desk above the page, with a small label over it.
        case heading
    }

    enum TitleLabel: CaseIterable {
        case title
        case sceneTitle

        var text: String {
            switch self {
            case .title: "Title"
            case .sceneTitle: "Scene title"
            }
        }
    }

    enum Toolbar: CaseIterable {
        /// c1: the system's window toolbar (`NSToolbar`, through SwiftUI's `.toolbar`).
        case native
        /// c2: a bar drawn in the window, like the mockup.
        case custom
    }

    enum PanelTabs: CaseIterable {
        /// d1: text tabs with an underline, like the mockup.
        case text
        /// d2: a segmented control.
        case segmented
    }

    enum StatusBar: CaseIterable {
        /// d1: plain gray text, like the mockup.
        case plain
        /// d2: the parts divided by thin rules.
        case divided
    }

    var railIcons = RailIcons.document
    var titlePlacement = TitlePlacement.strip
    var titleLabel = TitleLabel.title
    var toolbar = Toolbar.native
    var panelTabs = PanelTabs.text
    var statusBar = StatusBar.plain

    /// The recommendation, used by the app until the owner picks.
    static let recommended = WindowLook()

    func symbol(for item: WindowMode) -> String {
        switch (railIcons, item) {
        case (.document, .page): "doc.text"
        case (.document, .scenes): "square.grid.2x2"
        case (.document, .search): "magnifyingglass"
        case (.document, .fileCabinet): "archivebox"
        case (.cabinet, .page): "doc.plaintext"
        case (.cabinet, .scenes): "rectangle.grid.2x2"
        case (.cabinet, .search): "magnifyingglass"
        case (.cabinet, .fileCabinet): "tray.2"
        case (.text, .page): "text.page"
        case (.text, .scenes): "rectangle.stack"
        case (.text, .search): "text.magnifyingglass"
        case (.text, .fileCabinet): "tray.full"
        }
    }
}

extension EnvironmentValues {
    @Entry var windowLook = WindowLook.recommended
}

/// The window's fixed measurements (PLAN §4).
enum WindowMetrics {
    static let railWidth: CGFloat = 56
    static let panelWidth: CGFloat = 290
    static let collapsedPanelWidth: CGFloat = 28
    /// US Letter at 72 pt per inch, with 1 in margins.
    static let pageSize = CGSize(width: 612, height: 792)
    static let pageMargin: CGFloat = 72
    static let deskPadding: CGFloat = 28
    static let barHeight: CGFloat = 44
    static let statusBarHeight: CGFloat = 26
    static let deskColor = Color(red: 0.89, green: 0.89, blue: 0.87)
}
