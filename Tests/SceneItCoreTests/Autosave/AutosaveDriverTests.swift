import Testing

@testable import SceneItCore

extension AutosaveDriver {
    func wait(
        until condition: (AutosaveScheduler<C.Instant>.State) -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        while !condition(state) {
            do {
                try await nextEvent(orUntil: nil)
            } catch {
                Issue.record("cancelled before the condition held", sourceLocation: sourceLocation)
                return
            }
        }
    }

    var quitIsQueuedBehindASave: Bool {
        if case .saving(let saving) = state { saving.requestedNext == .quit } else { false }
    }
}

/// A saver that records when it ran and plays scripted outcomes; after the script, saves succeed.
@MainActor
private final class ScriptedSaver: AutosaveSaver {
    enum Step {
        case succeed
        /// Throws before suspending.
        case fail(SaveError)
        /// Waits for `release()`, then succeeds.
        case hold
    }

    private let clock: ManualClock
    private var steps: [Step]
    private(set) var times: [ManualClock.Instant] = []
    private(set) var requests: [SaveRequest] = []
    private var held: CheckedContinuation<Void, Never>?

    init(clock: ManualClock, _ steps: [Step] = []) {
        self.clock = clock
        self.steps = steps
    }

    func save(_ request: SaveRequest) async throws(SaveError) {
        times.append(clock.now)
        requests.append(request)
        let step = steps.isEmpty ? .succeed : steps.removeFirst()
        switch step {
        case .succeed:
            return
        case .fail(let error):
            throw error
        case .hold:
            await withCheckedContinuation { held = $0 }
        }
    }

    func untilHeld(sourceLocation: SourceLocation = #_sourceLocation) async {
        await eventually({ held != nil }, sourceLocation: sourceLocation)
    }

    func release() {
        held?.resume()
        held = nil
    }
}

/// A store that owns its driver and is its saver, the shape #11 will have.
@MainActor
private final class Store: AutosaveSaver {
    var text = 0
    var snapshots: [Int] = []
    var driver: AutosaveDriver<ManualClock>?

    init(clock: ManualClock) {
        driver = AutosaveDriver(clock: clock, saver: self)
    }

    func type(_ value: Int) {
        text = value
        driver?.send(.edited)
    }

    func save(_ request: SaveRequest) async throws(SaveError) {
        snapshots.append(text)
    }
}

@MainActor
private func makeDriver(_ steps: [ScriptedSaver.Step] = []) -> (
    ManualClock, ScriptedSaver, AutosaveDriver<ManualClock>
) {
    let clock = ManualClock()
    let saver = ScriptedSaver(clock: clock, steps)
    let driver = AutosaveDriver(clock: clock, saver: saver)
    return (clock, saver, driver)
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AutosaveDriverTests {
    @Test func savesAfterTheIdleDelayOnTheInjectedClock() async {
        let (clock, saver, driver) = makeDriver()
        driver.send(.edited)
        clock.advance(by: Interval(clamping: .milliseconds(1500)))
        driver.send(.edited)
        clock.advance(by: .seconds(2))
        await driver.wait { $0 == .clean }
        #expect(saver.times == [at(.milliseconds(3500))])
        #expect(saver.requests == [SaveRequest(.typingPaused)])
    }

    @Test func aFailedSaveIsRetriedAfterTheBackoff() async {
        let (clock, saver, driver) = makeDriver([.fail(diskFull)])
        driver.send(.edited)
        clock.advance(by: .seconds(2))
        await driver.wait { $0.quitDecision == .settled(.askWriter(.saveFailed(diskFull))) }
        #expect(driver.scheduler.failure?.consecutive == 1)
        clock.advance(by: .seconds(2))
        await driver.wait { $0 == .clean }
        #expect(saver.times == [at(.seconds(2)), at(.seconds(4))])
    }

    @Test func editsDuringARunningSaveAreSavedNext() async {
        let (clock, saver, driver) = makeDriver([.hold])
        driver.send(.edited)
        clock.advance(by: .seconds(2))
        await saver.untilHeld()
        driver.send(.edited)
        driver.send(.saveCommand)
        saver.release()
        await driver.wait { $0 == .clean }
        #expect(saver.times == [at(.seconds(2)), at(.seconds(2))])
    }

    @Test func theSaverSnapshotsInTheSameTurnAsSaveNow() async throws {
        let clock = ManualClock()
        let store = Store(clock: clock)
        let driver = try #require(store.driver)
        store.type(1)
        driver.send(.saveCommand)
        #expect(store.snapshots == [1])
        #expect(driver.state == .clean, "a saver that never suspends completes within send")
        store.type(2)
        clock.advance(by: .seconds(2))
        await driver.wait { $0 == .clean }
        #expect(store.snapshots == [1, 2])
    }

    @Test func aSaverThatThrowsSynchronouslyLeavesAConsistentState() async {
        let (clock, saver, driver) = makeDriver([.fail(diskFull)])
        driver.send(.edited)
        driver.send(.saveCommand)
        #expect(driver.scheduler.failure?.consecutive == 1)
        #expect(driver.state.quitDecision == .settled(.askWriter(.saveFailed(diskFull))))
        clock.advance(by: .seconds(2))
        await driver.wait { $0 == .clean }
        #expect(saver.times == [at(.zero), at(.seconds(2))])
    }

    @Test func aStoreThatOwnsItsDriverAndSavesForItIsFreed() {
        weak var weakStore: Store?
        do {
            let store = Store(clock: ManualClock())
            store.type(1)
            weakStore = store
        }
        #expect(weakStore == nil, "store -> driver must not lead back to the store")
    }

    @Test func aDriverWhoseSaverIsGoneNeverGetsStuckSaving() async throws {
        let clock = ManualClock()
        var saver: ScriptedSaver? = ScriptedSaver(clock: clock)
        let driver = AutosaveDriver(clock: clock, saver: try #require(saver))
        weak let gone = saver
        saver = nil
        try #require(gone == nil, "precondition: the saver was freed")
        driver.send(.edited)
        driver.send(.saveCommand)
        #expect(driver.state == .clean)
        #expect(try await driver.prepareToQuit() == .terminate)
    }

    // MARK: Quitting

    @Test func quittingSavesUnsavedEditsThenTerminates() async throws {
        let (_, saver, driver) = makeDriver()
        driver.send(.edited)
        #expect(try await driver.prepareToQuit() == .terminate)
        #expect(saver.times == [at(.zero)])
    }

    @Test func quittingWaitsForASaveInFlight() async throws {
        let (clock, saver, driver) = makeDriver([.hold])
        driver.send(.edited)
        clock.advance(by: .seconds(2))
        await saver.untilHeld()
        let quit = Task { try await driver.prepareToQuit() }
        await driver.wait { _ in driver.quitIsQueuedBehindASave }
        try #require(driver.quitIsQueuedBehindASave)
        saver.release()
        #expect(try await quit.value == .terminate)
        #expect(saver.times == [at(.seconds(2))])
    }

    @Test func aFailingSaveAtQuitAsksAndRetryCanSucceed() async throws {
        let (_, saver, driver) = makeDriver([.fail(diskFull)])
        driver.send(.edited)
        #expect(try await driver.prepareToQuit() == .askWriter(.saveFailed(diskFull)))
        #expect(try await driver.prepareToQuit() == .terminate)
        #expect(saver.times.count == 2)
    }

    @Test func quittingWhilePausedAsksWithoutSaving() async throws {
        let (_, saver, driver) = makeDriver([.fail(changedOnDisk)])
        driver.send(.edited)
        driver.send(.saveCommand)
        #expect(try await driver.prepareToQuit() == .askWriter(.changedOnDisk(changedOnDisk)))
        #expect(saver.times.count == 1)
    }

    @Test func aSlowSaveAtQuitAsksAfterTheGracePeriodAndWaitKeepsWaiting() async throws {
        let (clock, saver, driver) = makeDriver([.hold])
        driver.send(.edited)
        driver.send(.saveCommand)
        await saver.untilHeld()
        let firstQuit = Task { try await driver.prepareToQuit() }
        await driver.wait { _ in driver.quitIsQueuedBehindASave }
        clock.advance(by: AutosavePolicy.quitGracePeriod)
        #expect(try await firstQuit.value == .askWriter(.stillSaving))
        #expect(driver.quitIsQueuedBehindASave, "the save keeps running")

        let secondQuit = Task { try await driver.prepareToQuit() }
        await driver.wait { _ in driver.quitIsQueuedBehindASave }
        saver.release()
        #expect(try await secondQuit.value == .terminate)
        #expect(saver.times.count == 1)
    }

    @Test func cancellingAQuitStopsWaiting() async {
        let (_, saver, driver) = makeDriver([.hold])
        driver.send(.edited)
        driver.send(.saveCommand)
        await saver.untilHeld()
        let quit = Task { try await driver.prepareToQuit() }
        await driver.wait { _ in driver.quitIsQueuedBehindASave }
        quit.cancel()
        let result = await quit.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(driver.quitIsQueuedBehindASave, "the save keeps running")
        saver.release()
        await driver.wait { $0 == .clean }
    }
}
