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

    /// The Scenes sheet's Cards or Light table (PLAN §7.2, #28).
    @Test func theScenesViewIsKeptForTheNextLaunchAndStartsAsCards() {
        let storage = TransientPreferenceStorage()
        #expect(AppPreferences(storage).scenesView == .cards)
        AppPreferences(storage).showScenes(as: .lightTable)
        #expect(storage.values == ["scenesView": "lightTable"])
        #expect(AppPreferences(storage).scenesView == .lightTable)
        #expect(AppPreferences(TransientPreferenceStorage(["scenesView": "corkboard"])).scenesView == .cards)
    }

    @Test func unknownStoredValuesAreTheDefaults() {
        let preferences = AppPreferences(
            TransientPreferenceStorage(["rightPanelOpen": "sideways", "rightPanelTab": "outline"]))
        #expect(preferences.rightPanel == .open)
        #expect(preferences.rightPanelTab == .comments)
    }

    @Test func zoomIsKeptForTheNextLaunchAndStartsAt100Percent() {
        let storage = TransientPreferenceStorage()
        let preferences = AppPreferences(storage)
        #expect(preferences.zoom == .standard)
        preferences.setZoom(Zoom(clamping: 1.25))
        #expect(storage.values == ["zoom": "1.25"])
        #expect(AppPreferences(storage).zoom == Zoom(clamping: 1.25))
    }

    @Test func aStoredZoomOutsideTheRangeOrUnreadableIs100Percent() {
        for stored in ["9", "0.1", "nan", "-0.5", "large", ""] {
            #expect(
                AppPreferences(TransientPreferenceStorage(["zoom": stored])).zoom == .standard, "\(stored)")
        }
        #expect(AppPreferences(TransientPreferenceStorage(["zoom": "3"])).zoom == Zoom(clamping: 3))
    }

    @Test func zoomStepsStopAtTheEndsOfTheRange() {
        let preferences = AppPreferences(TransientPreferenceStorage())
        preferences.zoom(.zoomIn)
        #expect(preferences.zoom == Zoom(clamping: 1.1))
        preferences.setZoom(Zoom(clamping: 3))
        #expect(!preferences.canZoom(.zoomIn))
        #expect(preferences.canZoom(.zoomOut))
        preferences.zoom(.zoomIn)
        #expect(preferences.zoom == Zoom(clamping: 3))
        preferences.setZoom(Zoom(clamping: 0.5))
        #expect(!preferences.canZoom(.zoomOut))
        preferences.zoom(.zoomOut)
        #expect(preferences.zoom == Zoom(clamping: 0.5))
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

    /// A comment can be any palette color, black included (book format §4.4), and starts purple.
    @Test func aCommentColorIsRememberedBlackIncluded() {
        let storage = TransientPreferenceStorage()
        let preferences = AppPreferences(storage)
        #expect(preferences.lastCommentColor == .purple)
        preferences.rememberCommentColor(.black)
        #expect(preferences.lastCommentColor == .black)
        #expect(storage.values == ["lastCommentColor": "black"])
        #expect(AppPreferences(storage).lastCommentColor == .black)
        #expect(
            AppPreferences(TransientPreferenceStorage(["lastCommentColor": "mauve"])).lastCommentColor
                == .purple)
    }

    @Test func unknownStoredColorsAreTheDefaults() {
        let preferences = AppPreferences(
            TransientPreferenceStorage(["lastTextColor": "black", "lastHighlight": "mauve"]))
        #expect(preferences.lastTextColor == .purple)
        #expect(preferences.lastHighlight == .green)
    }
}
