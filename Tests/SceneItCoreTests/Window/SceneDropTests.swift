import Testing

@testable import SceneItCore

private func id(_ raw: String) -> SceneID {
    SceneID(rawValue: raw)
}

/// A drag in the Scenes sheet (PLAN §7.2, §7.3): where the slot shows, when the tray lights, and
/// what each drop changes.
@Suite struct SceneDropTests {
    @Test func aCardOverAnotherShowsTheSlotBeforeItWhichStaysAsThePointerMovesOntoTheSlot() {
        var drop = SceneDropState.idle
        drop.begin(.card(id("a")))
        #expect(drop.slot == nil && !drop.isOverTray)
        drop.enter(.card(id("c")))
        #expect(drop.slot == .before(id("c")))
        // The slot pushes card c along, so the pointer is over the slot now.
        drop.exit(.card(id("c")))
        drop.enter(.slot)
        #expect(drop.slot == .before(id("c")))
        #expect(drop.drop(on: .slot) == .move(id("a"), to: .before(id("c"))))
        #expect(drop.drag == nil && drop.slot == nil, "the drag is over")
    }

    @Test func theSlotGoesWhenThePointerLeavesTheGrid() {
        var drop = SceneDropState.idle
        drop.begin(.tile(id("x")))
        drop.enter(.end)
        #expect(drop.slot == .end)
        drop.exit(.end)
        #expect(drop.slot == nil)
    }

    @Test func aCardOverTheTrayLightsItAndIsCutThere() {
        var drop = SceneDropState.idle
        drop.begin(.card(id("a")))
        drop.enter(.card(id("b")))
        drop.exit(.card(id("b")))
        drop.enter(.tray)
        #expect(drop.isOverTray && drop.slot == nil, "the slot leaves the grid as the tray lights")
        drop.exit(.tray)
        #expect(!drop.isOverTray)
        drop.enter(.tray)
        #expect(drop.drop(on: .tray) == .cut(id("a")))
    }

    /// The order AppKit reports a move between zones in doesn't matter.
    @Test func enteringBeforeLeavingKeepsTheNewZone() {
        var drop = SceneDropState.idle
        drop.begin(.card(id("a")))
        drop.enter(.card(id("b")))
        drop.enter(.tray)
        drop.exit(.card(id("b")))
        #expect(drop.isOverTray && drop.slot == nil)
    }

    @Test func aTileIsRestoredInTheGridAndTheTrayRefusesIt() {
        var drop = SceneDropState.idle
        drop.begin(.tile(id("x")))
        #expect(!drop.accepts(.tray))
        drop.enter(.tray)
        #expect(!drop.isOverTray, "the tray doesn't light for its own tile")
        #expect(drop.drop(on: .tray) == nil)

        drop.begin(.tile(id("x")))
        drop.enter(.card(id("b")))
        #expect(drop.drop(on: .card(id("b"))) == .restore(id("x"), to: .before(id("b"))))
        drop.begin(.tile(id("x")))
        drop.enter(.end)
        #expect(drop.drop(on: .end) == .restore(id("x"), to: .end))
    }

    /// A card's slot just before itself, or just before the card after it, would change nothing,
    /// so it doesn't show; a tile's always does.
    @Test func noSlotShowsWhereACardWouldStayWhereItIs() {
        let scenes = ["a", "b", "c"].map {
            BookScene(
                id: id($0), modified: Timestamp(secondsSince1970: 0, offset: .zero), title: SceneTitle($0))
        }
        let book = Book(title: "Novel", scenes: scenes, boneyard: [])
        var drop = SceneDropState.idle
        drop.begin(.card(id("b")))
        #expect(drop.drag?.scene == id("b"))
        for (zone, shown) in [
            (DropZone.card(id("b")), nil), (.card(id("c")), nil), (.card(id("a")), StorySlot.before(id("a"))),
            (.end, .end),
        ] {
            drop.enter(zone)
            #expect(drop.slot(in: book) == shown)
            drop.exit(zone)
        }
        drop.begin(.card(id("c")))
        drop.enter(.end)
        #expect(drop.slot == .end && drop.slot(in: book) == nil, "the last card at the end")
        drop.begin(.tile(id("x")))
        drop.enter(.card(id("a")))
        #expect(drop.slot(in: book) == .before(id("a")))
    }

    @Test func nothingIsAcceptedWithoutADragAndADroppedSlotNeedsASlot() {
        var drop = SceneDropState.idle
        #expect(!drop.accepts(.card(id("a"))))
        #expect(drop.drop(on: .card(id("a"))) == nil)
        drop.begin(.card(id("a")))
        #expect(drop.drop(on: .slot) == nil, "a slot nobody placed")
        drop.begin(.card(id("a")))
        drop.enter(.end)
        drop.end()
        #expect(drop == .idle)
    }

    // MARK: The arrow keys

    /// Seven cards in three columns:
    /// a b c
    /// d e f
    /// g
    let grid = CardGrid(cards: ["a", "b", "c", "d", "e", "f", "g"].map(id), columns: 3)

    @Test func leftAndRightFollowTheStoryFromRowToRowAndStopAtTheEnds() {
        #expect(grid.neighbor(of: id("b"), .right) == id("c"))
        #expect(grid.neighbor(of: id("c"), .right) == id("d"))
        #expect(grid.neighbor(of: id("d"), .left) == id("c"))
        #expect(grid.neighbor(of: id("a"), .left) == nil)
        #expect(grid.neighbor(of: id("g"), .right) == nil)
    }

    @Test func upAndDownGoARowAndStopAtTheEnds() {
        #expect(grid.neighbor(of: id("e"), .up) == id("b"))
        #expect(grid.neighbor(of: id("b"), .down) == id("e"))
        #expect(grid.neighbor(of: id("b"), .up) == nil, "the first row")
        #expect(grid.neighbor(of: id("d"), .down) == id("g"))
        #expect(grid.neighbor(of: id("f"), .down) == id("g"), "to the last card, below and to the left")
        #expect(grid.neighbor(of: id("g"), .down) == nil, "the last row")
        #expect(grid.neighbor(of: id("g"), .up) == id("d"))
    }

    @Test func oneColumnOrOneCard() {
        let column = CardGrid(cards: ["a", "b"].map(id), columns: 0)
        #expect(column.columns == 1)
        #expect(column.neighbor(of: id("a"), .down) == id("b"))
        #expect(column.neighbor(of: id("b"), .up) == id("a"))
        let single = CardGrid(cards: [id("a")], columns: 4)
        #expect(GridStep.allCases.allSatisfy { single.neighbor(of: id("a"), $0) == nil })
        #expect(grid.neighbor(of: id("hidden"), .right) == nil)
    }

    @Test func theKeysStartFromTheOpenScenesCardOrTheFirst() {
        #expect(grid.start(at: id("e")) == id("e"))
        #expect(grid.start(at: id("hidden")) == id("a"))
        #expect(grid.start(at: nil) == id("a"))
        #expect(CardGrid(cards: [], columns: 3).start(at: nil) == nil)
    }
}
