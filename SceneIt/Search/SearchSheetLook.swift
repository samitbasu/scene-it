import SwiftUI

/// The Search sheet's look while the owner chooses it (#31, phase 1): each choice the mockup
/// leaves open, with its candidates. The window uses `recommended`; once the owner picks, the
/// candidates go and the picks become plain code.
struct SearchSheetLook: Hashable {
    enum Options: Hashable, CaseIterable {
        /// The mockup's single row: field, Search tags, scope, Match case, Whole word.
        case oneRow
        /// The field and the scope on the first row; the three checkboxes under the field.
        case twoRows
        /// The mockup's row with File Cabinet in the scope, disabled until #34.
        case oneRowWithCabinet
    }

    enum Rows: Hashable, CaseIterable {
        /// A card per scene showing its best hit, then "+N more in this scene", which expands.
        case bestThenMore
        /// A card per scene showing its best three hits, then "+N more in this scene".
        case firstThreeThenMore
        /// No cards: one line per scene, its number, title and best hit, then "+N more".
        case compact
    }

    enum MatchMark: Hashable, CaseIterable {
        /// The mockup's yellow marker.
        case yellow
        /// The yellow marker, in bold.
        case yellowBold
        /// The accent color's tint, as the rail's selected icon.
        case accentTint
    }

    enum DiffersMark: Hashable, CaseIterable {
        /// PLAN §9.2's underline: solid, orange.
        case orangeUnderline
        /// A dotted red underline, like a spelling mark.
        case dottedRed
        /// A light gray marker with a dashed underline.
        case grayDashed
    }

    var options = Options.oneRow
    var rows = Rows.bestThenMore
    var match = MatchMark.yellow
    var differs = DiffersMark.orangeUnderline

    static let recommended = SearchSheetLook()

    /// How many of a scene's hits its card shows before "+N more".
    var hitsBeforeMore: Int {
        switch rows {
        case .bestThenMore, .compact: 1
        case .firstThreeThenMore: 3
        }
    }
}

extension EnvironmentValues {
    @Entry var searchSheetLook = SearchSheetLook.recommended
}
