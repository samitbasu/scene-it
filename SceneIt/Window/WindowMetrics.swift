import SwiftUI

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
