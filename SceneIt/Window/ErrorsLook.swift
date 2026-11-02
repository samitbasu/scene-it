import SceneItCore
import SwiftUI

// TEMPORARY (#63, #67): the looks rendered for the owner's pick. The defaults are the
// recommendation; once the owner chooses, the others and this knob go.

struct ErrorsLook: Hashable {
    var tabVisibility = ErrorsTabVisibility.whenPresent
    var rows = ErrorRowStyle.cards
    var banner = BannerStyle.yellowStrip
}

enum ErrorRowStyle: Hashable, CaseIterable {
    /// One line of reason, one of payload, and a ⋯ menu.
    case compact
    /// A card per entry: tag, reason, the payload in a box, and a row of actions.
    case cards
    /// The tag and reason, with the payload and actions under a disclosure triangle.
    case disclosure
}

enum BannerStyle: Hashable, CaseIterable {
    /// Across the window under the toolbar, pale yellow, like the mockup's filed-copy banner.
    case yellowStrip
    /// Across the window under the toolbar, in the system's neutral bar material.
    case infoBar
    /// Inside the editor column only, above the scene's Title strip.
    case inline
}

extension EnvironmentValues {
    @Entry var errorsLook = ErrorsLook()
    /// For renders: the row that starts with its payload being edited.
    @Entry var errorsEditing: ErrorRef?
}
