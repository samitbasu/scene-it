import Foundation
import Testing

@testable import SceneItCore

@Suite @MainActor
struct AppPreferencesTests {
    @Test func defaultsAreAnOpenPanelOnComments() {
        let preferences = AppPreferences(TransientPreferenceStorage())
        #expect(preferences.rightPanel == .open)
        #expect(preferences.rightPanelTab == .comments)
    }

    @Test func choicesAreKeptForTheNextLaunch() {
        let storage = TransientPreferenceStorage()
        let preferences = AppPreferences(storage)
        preferences.toggleRightPanel()
        preferences.showRightPanelTab(.tags)
        #expect(preferences.rightPanel == .closed)
        #expect(storage.values == ["rightPanelOpen": "closed", "rightPanelTab": "tags"])

        let next = AppPreferences(storage)
        #expect(next.rightPanel == .closed)
        #expect(next.rightPanelTab == .tags)
        next.toggleRightPanel()
        #expect(next.rightPanel == .open)
    }

    @Test func unknownStoredValuesAreTheDefaults() {
        let preferences = AppPreferences(
            TransientPreferenceStorage(["rightPanelOpen": "sideways", "rightPanelTab": "errors"]))
        #expect(preferences.rightPanel == .open)
        #expect(preferences.rightPanelTab == .comments)
    }
}
