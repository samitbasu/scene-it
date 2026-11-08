import Testing

@testable import SceneItCore

@Suite struct FocusModeTests {
    @Test func focusModeHidesTheRailToolbarPanelAndStatusBar() {
        for part in ChromePart.allCases {
            #expect(FocusMode.off.shows(part, under: .recommended), "\(part) shows outside focus mode")
        }
        for part in [ChromePart.rail, .toolbar, .rightPanel, .statusBar] {
            #expect(!FocusMode.on.shows(part, under: .recommended), "\(part) hides in focus mode")
        }
    }

    @Test func theFormattingBarFollowsItsRule() {
        var rules = FocusModeRules.recommended
        #expect(FocusMode.on.shows(.formattingBar, under: rules), "recommended: the bar stays")
        rules.formattingBar = .hidden
        #expect(!FocusMode.on.shows(.formattingBar, under: rules))
        #expect(FocusMode.off.shows(.formattingBar, under: rules))
    }

    @Test func scenesAndSheetsKeepOrLeaveFocusModeAsTheRulesSay() {
        var rules = FocusModeRules.recommended
        for event in [FocusModeEvent.sceneOpened, .sheetOpened] {
            #expect(FocusMode.on.after(event, under: rules) == .on, "recommended: \(event) stays")
            #expect(FocusMode.off.after(event, under: rules) == .off)
        }
        rules.sceneSwitch = .leavesFocusMode
        #expect(FocusMode.on.after(.sceneOpened, under: rules) == .off)
        #expect(FocusMode.on.after(.sheetOpened, under: rules) == .on)
        rules.sheets = .leaveFocusMode
        #expect(FocusMode.on.after(.sheetOpened, under: rules) == .off)
        #expect(FocusMode.off.after(.sheetOpened, under: rules) == .off)
    }

    @Test func toggledFlips() {
        #expect(FocusMode.off.toggled == .on)
        #expect(FocusMode.on.toggled == .off)
    }
}

@Suite struct EscapeOrderTests {
    private func context(
        popover: Presence = .absent, dialog: Presence = .absent, mode: WindowMode = .page,
        focusMode: FocusMode = .off
    ) -> EscapeContext {
        EscapeContext(popover: popover, dialog: dialog, mode: mode, focusMode: focusMode)
    }

    @Test func escClosesPopoversThenDialogsThenSheetsThenFocusMode() {
        let everything = context(popover: .present, dialog: .present, mode: .search, focusMode: .on)
        #expect(EscapeLayer.closedByEscape(in: everything) == .popover)
        #expect(
            EscapeLayer.closedByEscape(in: context(dialog: .present, mode: .search, focusMode: .on))
                == .dialog)
        #expect(EscapeLayer.closedByEscape(in: context(mode: .search, focusMode: .on)) == .sheet)
        #expect(EscapeLayer.closedByEscape(in: context(focusMode: .on)) == .focusMode)
        #expect(EscapeLayer.closedByEscape(in: context()) == nil, "nothing to close: the view's own Esc")
    }

    @Test func eachLayerAloneIsWhatEscCloses() {
        #expect(EscapeLayer.closedByEscape(in: context(popover: .present)) == .popover)
        #expect(EscapeLayer.closedByEscape(in: context(dialog: .present)) == .dialog)
        for sheet in WindowMode.allCases.filter(\.isSheet) {
            #expect(EscapeLayer.closedByEscape(in: context(mode: sheet)) == .sheet, "\(sheet)")
        }
        #expect(EscapeLayer.closedByEscape(in: context(popover: .present, focusMode: .on)) == .popover)
    }

    /// Closing what Esc names, again and again, unwinds the window one layer at a time.
    @Test func repeatedEscUnwindsOneLayerAtATime() {
        var state = context(popover: .present, dialog: .present, mode: .scenes, focusMode: .on)
        var closed: [EscapeLayer] = []
        while let layer = EscapeLayer.closedByEscape(in: state) {
            closed.append(layer)
            switch layer {
            case .popover: state.popover = .absent
            case .dialog: state.dialog = .absent
            case .sheet: state.mode = state.mode.closingSheet
            case .focusMode: state.focusMode = .off
            }
        }
        #expect(closed == EscapeLayer.allCases)
        #expect(closed == [.popover, .dialog, .sheet, .focusMode])
    }
}

@Suite struct TabOrderTests {
    @Test func tabGoesPagePanelSearchFieldAndRound() {
        #expect(TabStop.page.following(.forward) == [.panel, .searchField])
        #expect(TabStop.panel.following(.forward) == [.searchField, .page])
        #expect(TabStop.searchField.following(.forward) == [.page, .panel])
    }

    @Test func shiftTabGoesTheOtherWay() {
        #expect(TabStop.page.following(.backward) == [.searchField, .panel])
        #expect(TabStop.panel.following(.backward) == [.page, .searchField])
        #expect(TabStop.searchField.following(.backward) == [.panel, .page])
    }
}
