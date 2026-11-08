import Foundation

/// The system's ways of changing the writer's words as they type (#127): correcting spelling,
/// completing words, predicting inline, capitalizing, a period for a double space, and smart
/// quotes and dashes. They start off in Scene It, and the writer turns each on or off from the
/// Edit menu or a text view's context menu, as in any Mac app (ADR 0028).
enum AutomaticTextChanges {
    /// The user-defaults keys AppKit reads them from, each starting off. They go in the
    /// registration domain, which is never saved: a choice the writer makes from a menu, which
    /// AppKit saves in the app's own defaults, outranks it, and so do System Settings' own.
    static let startingValues: [String: Any] = [
        "NSAutomaticSpellingCorrectionEnabled": false,
        "NSAutomaticTextCompletionEnabled": false,
        "NSAutomaticInlinePredictionEnabled": false,
        "NSAutomaticCapitalizationEnabled": false,
        "NSAutomaticPeriodSubstitutionEnabled": false,
        "NSAutomaticQuoteSubstitutionEnabled": false,
        "NSAutomaticDashSubstitutionEnabled": false,
    ]

    /// Registers the starting values, before any text view reads them.
    static func registerStartingValues(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: startingValues)
    }
}
