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
            TransientPreferenceStorage(["rightPanelOpen": "sideways", "rightPanelTab": "outline"]))
        #expect(preferences.rightPanel == .open)
        #expect(preferences.rightPanelTab == .comments)
    }

    @Test func revealOpensThePanelOnTheTab() {
        let preferences = AppPreferences(TransientPreferenceStorage())
        preferences.setRightPanel(.closed)
        preferences.reveal(.errors)
        #expect(preferences.rightPanel == .open)
        #expect(preferences.rightPanelTab == .errors)
    }

    @Test func theErrorsTabShowsOnlyWhileThereAreEntries() {
        #expect(RightPanelTab.shown(errorCount: 0) == [.comments, .notes, .tags])
        #expect(RightPanelTab.shown(errorCount: 3) == [.comments, .notes, .tags, .errors])
        let hidden = RightPanelTab.shown(errorCount: 0)
        #expect(RightPanelTab.selected(.errors, among: hidden) == .comments, "the last entry went")
        #expect(RightPanelTab.selected(.tags, among: hidden) == .tags)
    }
}

@Suite @MainActor
struct LastUsedColorTests {
    @Test func theBarStartsOnPurpleAndGreen() {
        let preferences = AppPreferences(TransientPreferenceStorage())
        #expect(preferences.lastTextColor == .purple)
        #expect(preferences.lastHighlight == .green)
    }

    @Test func aChosenColorIsRememberedButBlackAndNoneAreNot() {
        let storage = TransientPreferenceStorage()
        let preferences = AppPreferences(storage)
        preferences.remember(.textColor(.red))
        preferences.remember(.highlight(.blue))
        preferences.remember(.textColor(.black))
        preferences.remember(.highlight(nil))
        preferences.remember(.toggle(.bold))
        #expect(preferences.lastTextColor == .red)
        #expect(preferences.lastHighlight == .blue)
        #expect(storage.values == ["lastTextColor": "red", "lastHighlight": "blue"])
        let next = AppPreferences(storage)
        #expect(next.lastTextColor == .red)
        #expect(next.lastHighlight == .blue)
    }

    @Test func unknownStoredColorsAreTheDefaults() {
        let preferences = AppPreferences(
            TransientPreferenceStorage(["lastTextColor": "black", "lastHighlight": "mauve"]))
        #expect(preferences.lastTextColor == .purple)
        #expect(preferences.lastHighlight == .green)
    }
}
