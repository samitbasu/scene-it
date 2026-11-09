import SwiftUI

/// The window's fixed measurements (PLAN §4).
enum WindowMetrics {
    static let railWidth: CGFloat = 56
    static let railButtonSize: CGFloat = 40
    static let railButtonCornerRadius: CGFloat = 9
    static let railDividerWidth: CGFloat = 28
    static let panelWidth: CGFloat = 290
    static let collapsedPanelWidth: CGFloat = 28
    /// US Letter at 72 pt per inch, with 1 in margins. A scene is one continuous sheet this
    /// wide, never shorter than this, growing as the text does.
    static let pageSize = CGSize(width: 612, height: 792)
    static let pageMargin: CGFloat = 72
    static let textColumnWidth = pageSize.width - 2 * pageMargin
    static let deskPadding: CGFloat = 28
    /// The page's shadow on the desk: its opacity, blur radius and downward offset.
    static let pageShadow = (opacity: 0.12, radius: CGFloat(3), drop: CGFloat(1))
    static let barHeight: CGFloat = 44

    /// The formatting bar, as the owner picked it (#18): plain glyph buttons; a filled background
    /// for state, darker for on and lighter for mixed; the color and highlight buttons each with
    /// a separate ▾ opening a row of swatches; the "A" over a colored bar and the "A" on a
    /// colored tile.
    enum Bar {
        static let buttonSize = CGSize(width: 26, height: 24)
        static let arrowWidth: CGFloat = 14
        static let cornerRadius: CGFloat = 5
        static let buttonSpacing: CGFloat = 2
        static let groupSpacing: CGFloat = 8
        /// The opacities of the primary color behind a button.
        static let onFill = 0.14
        static let mixedFill = 0.06
        static let pressedFill = 0.2
        /// The whole bar while the page can't be formatted.
        static let dimmedOpacity = 0.35
        static let colorBarSize = CGSize(width: 13, height: 3)
        static let highlightTile: CGFloat = 18
        static let swatchSize: CGFloat = 18
    }
    /// The Search sheet, from the mockup (10-search-whole-book.png).
    enum Search {
        static let headerSpacing: CGFloat = 14
        static let fieldWidth: CGFloat = 360
        static let bodyPadding: CGFloat = 16
        static let groupSpacing: CGFloat = 12
        static let groupCornerRadius: CGFloat = 8
        static let rowPadding = EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        static let headerPadding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        static let numberSize: CGFloat = 24
        static let labelWidth: CGFloat = 52
        static let snippetSize: CGFloat = 15
        static let background = Color(red: 0xF3 / 255, green: 0xF2 / 255, blue: 0xEF / 255)
        static let groupHeader = Color(red: 0xF0 / 255, green: 0xEF / 255, blue: 0xEB / 255)
        static let line = Color(red: 0xD9 / 255, green: 0xD7 / 255, blue: 0xD1 / 255)
        static let rowLine = Color(red: 0xEE / 255, green: 0xED / 255, blue: 0xE9 / 255)
        static let hover = Color(red: 0xE8 / 255, green: 0xEF / 255, blue: 0xFB / 255)
        static let marker = Color(red: 0xFF / 255, green: 0xE5 / 255, blue: 0x8A / 255)
    }
    enum Notes {
        /// Between the panel's edges and the notes' text.
        static let padding = CGSize(width: 14, height: 12)
    }
    static let statusBarHeight: CGFloat = 26
    static let titleStripPadding: CGFloat = 10
    /// Between the title's label and its field.
    static let titleLabelGap: CGFloat = 10
    static let deskColor = Color(red: 0.89, green: 0.89, blue: 0.87)
    static let bannerHeight: CGFloat = 44
    /// The ring around the Errors tab while it has the keyboard focus.
    static let focusRingWidth: CGFloat = 3
    static let focusRingRadius: CGFloat = 6
    /// The mockup's read-only banner (13-read-only-filed-copy.png).
    static let bannerColor = Color(red: 0.99, green: 0.95, blue: 0.84)
    /// A filed copy's page (mockup 13's light gray, #EBE9E4).
    static let filedCopyPaper = Color(red: 0xEB / 255, green: 0xE9 / 255, blue: 0xE4 / 255)

    static let defaultSize = CGSize(width: 1440, height: 900)
    /// Room for the rail, the whole page on its desk and the open panel, side by side.
    static let minimumSize = CGSize(
        width: railWidth + pageSize.width + 2 * deskPadding + panelWidth + 2 * dividerAllowance,
        height: 640)
    private static let dividerAllowance: CGFloat = 1
}
