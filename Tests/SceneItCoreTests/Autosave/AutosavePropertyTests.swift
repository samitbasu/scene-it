import Testing

@testable import SceneItCore

/// Plays a scheduler the way the driver does (ticks at its deadlines, saves when told, one at a
/// time), and tracks which edits a successful save has covered.
private struct Simulation {
    var scheduler = Scheduler()
    var now = at(.zero)
    var deadline: ManualClock.Instant?
    var editCount = 0
    var savedEditCount = 0
    var inFlightCovers: Int?

    mutating func send(_ event: AutosaveEvent) {
        if event == .saveSucceeded, let covers = inFlightCovers {
            savedEditCount = covers
        }
        if case .saveSucceeded = event { inFlightCovers = nil }
        if case .saveFailed = event { inFlightCovers = nil }
        if event == .edited { editCount += 1 }

        let decision = scheduler.handle(event, at: now)
        deadline = nil
        switch decision {
        case .idle:
            break
        case .waitUntil(let instant):
            #expect(instant > now, "a deadline must lie in the future")
            deadline = instant
        case .saveNow:
            #expect(inFlightCovers == nil, "two saves must never overlap")
            inFlightCovers = editCount
        }
        checkInvariants(after: decision)
    }

    /// Lets time pass, delivering the tick the driver would at any deadline on the way.
    mutating func advance(by offset: Duration) {
        let target = now.advanced(by: offset)
        while let deadline, deadline <= target {
            now = deadline
            send(.tick)
        }
        now = target
    }

    func checkInvariants(after decision: Scheduler.Decision) {
        let unsavedEdits = editCount > savedEditCount
        switch scheduler.state {
        case .clean:
            #expect(!unsavedEdits, "clean must mean every edit was saved")
            #expect(inFlightCovers == nil)
            #expect(decision == .idle)
        case .unsaved:
            #expect(unsavedEdits)
            #expect(inFlightCovers == nil)
            #expect(decision != .idle, "unsaved edits need a pending save")
        case .saving:
            #expect(inFlightCovers != nil, "the scheduler and the driver agree a save is running")
        case .paused:
            #expect(unsavedEdits)
            #expect(inFlightCovers == nil)
        }
    }
}

@Test func unsavedEditsAlwaysHaveAPendingSaveAFailureOrAPause() {
    let events: [AutosaveEvent] = [
        .edited, .edited, .edited, .edited, .sceneSwitched, .appDeactivated, .quitRequested,
        .saveCommand, .externalChangeResolved, .tick, .saveSucceeded, .saveFailed(diskFull),
    ]
    for seed in UInt64(1)...300 {
        var random = SplitMix64(seed: seed)
        var simulation = Simulation()
        for _ in 0..<400 {
            simulation.advance(by: .milliseconds(Int.random(in: 0...4000, using: &random)))
            if simulation.inFlightCovers != nil, Int.random(in: 0..<4, using: &random) == 0 {
                let outcomes: [AutosaveEvent] = [
                    .saveSucceeded, .saveFailed(diskFull), .saveFailed(changedOnDisk),
                ]
                simulation.send(outcomes.randomElement(using: &random)!)
            } else {
                simulation.send(events.randomElement(using: &random)!)
            }
        }

        // Once editing stops and saves succeed, everything reaches disk within a bounded time.
        for _ in 0..<10 where simulation.scheduler.state != .clean {
            if case .paused = simulation.scheduler.state { simulation.send(.externalChangeResolved) }
            if simulation.inFlightCovers != nil { simulation.send(.saveSucceeded) }
            simulation.advance(by: AutosavePolicy.maximumDelay.duration)
        }
        #expect(simulation.scheduler.state == .clean, "seed \(seed)")
        #expect(simulation.savedEditCount == simulation.editCount, "seed \(seed)")
    }
}
