import SwiftUI

/// The window's fixed measurements (PLAN §4).
enum WindowMetrics {
    static let railWidth: CGFloat = 56
    static let railButtonSize: CGFloat = 40
    static let railButtonCornerRadius: CGFloat = 9
    static let railDividerWidth: CGFloat = 28
    static let panelWidth: CGFloat = 290
    static let collapsedPanelWidth: CGFloat = 28
    /// US Letter at 72 pt per inch, with 1 in margins.
    static let pageSize = CGSize(width: 612, height: 792)
    static let pageMargin: CGFloat = 72
    static let deskPadding: CGFloat = 28
    /// The page's shadow on the desk: its opacity, blur radius and downward offset.
    static let pageShadow = (opacity: 0.12, radius: CGFloat(3), drop: CGFloat(1))
    static let barHeight: CGFloat = 44
    static let statusBarHeight: CGFloat = 26
    static let titleStripPadding: CGFloat = 10
    /// Between the title's label and its field.
    static let titleLabelGap: CGFloat = 10
    static let deskColor = Color(red: 0.89, green: 0.89, blue: 0.87)
    static let bannerHeight: CGFloat = 44
    /// The mockup's read-only banner (13-read-only-filed-copy.png).
    static let bannerColor = Color(red: 0.99, green: 0.95, blue: 0.84)

    static let defaultSize = CGSize(width: 1440, height: 900)
    /// Room for the rail, the whole page on its desk and the open panel, side by side.
    static let minimumSize = CGSize(
        width: railWidth + pageSize.width + 2 * deskPadding + panelWidth + 2 * dividerAllowance,
        height: 640)
    private static let dividerAllowance: CGFloat = 1
}
