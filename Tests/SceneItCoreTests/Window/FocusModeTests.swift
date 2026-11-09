import Testing

@testable import SceneItCore

@Suite struct FocusModeTests {
    @Test func focusModeHidesTheRailToolbarPanelAndStatusBar() {
        for part in ChromePart.allCases {
            #expect(FocusMode.off.shows(part), "\(part) shows outside focus mode")
            #expect(!FocusMode.on.shows(part), "\(part) hides in focus mode")
        }
        #expect(ChromePart.allCases == [.rail, .toolbar, .rightPanel, .statusBar], "the bar isn't chrome")
    }

    @Test func toggledFlips() {
        #expect(FocusMode.off.toggled == .on)
        #expect(FocusMode.on.toggled == .off)
    }
}

@Suite struct EscapeOrderTests {
    private func context(
        popover: Presence = .absent, dialog: DialogStage? = nil, mode: WindowMode = .page,
        findBar: Presence = .absent, focusMode: FocusMode = .off
    ) -> EscapeContext {
        EscapeContext(popover: popover, dialog: dialog, mode: mode, findBar: findBar, focusMode: focusMode)
    }

    @Test func escClosesPopoversThenDialogsThenSheetsThenTheFindBarThenFocusMode() {
        #expect(
            EscapeLayer.escape(
                in: context(
                    popover: .present, dialog: .open, mode: .search, findBar: .present, focusMode: .on))
                == .close(.popover))
        #expect(
            EscapeLayer.escape(
                in: context(dialog: .open, mode: .search, findBar: .present, focusMode: .on))
                == .close(.dialog))
        #expect(
            EscapeLayer.escape(in: context(mode: .search, findBar: .present, focusMode: .on))
                == .close(.sheet),
            "a sheet covers the find bar, so Esc can't close a find bar it hides")
        #expect(EscapeLayer.escape(in: context(findBar: .present, focusMode: .on)) == .close(.findBar))
        #expect(EscapeLayer.escape(in: context(focusMode: .on)) == .close(.focusMode))
        #expect(EscapeLayer.escape(in: context()) == .passOn, "nothing to close: the view's own Esc")
    }

    @Test func eachLayerAloneIsWhatEscCloses() {
        #expect(EscapeLayer.escape(in: context(popover: .present)) == .close(.popover))
        #expect(EscapeLayer.escape(in: context(dialog: .open)) == .close(.dialog))
        for sheet in WindowMode.allCases.filter(\.isSheet) {
            #expect(EscapeLayer.escape(in: context(mode: sheet)) == .close(.sheet), "\(sheet)")
        }
        #expect(EscapeLayer.escape(in: context(findBar: .present)) == .close(.findBar))
    }

    /// While File a Copy files, Esc closes nothing: not the dialog, whose draft a failed filing
    /// still needs, and not what's under it.
    @Test func escHoldsWhileTheDialogFiles() {
        #expect(EscapeLayer.escape(in: context(dialog: .busy)) == .hold(.dialog))
        #expect(
            EscapeLayer.escape(in: context(dialog: .busy, mode: .scenes, focusMode: .on)) == .hold(.dialog))
        #expect(EscapeLayer.escape(in: context(popover: .present, dialog: .busy)) == .close(.popover))
    }

    /// Closing what Esc names, again and again, unwinds the window one layer at a time.
    @Test func repeatedEscUnwindsOneLayerAtATime() {
        var state = context(
            popover: .present, dialog: .open, mode: .scenes, findBar: .present, focusMode: .on)
        var closed: [EscapeLayer] = []
        while case .close(let layer) = EscapeLayer.escape(in: state) {
            closed.append(layer)
            switch layer {
            case .popover: state.popover = .absent
            case .dialog: state.dialog = nil
            case .sheet: state.mode = state.mode.closingSheet
            case .findBar: state.findBar = .absent
            case .focusMode: state.focusMode = .off
            }
        }
        #expect(closed == EscapeLayer.allCases)
        #expect(closed == [.popover, .dialog, .sheet, .findBar, .focusMode])
        #expect(EscapeLayer.escape(in: state) == .passOn)
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
