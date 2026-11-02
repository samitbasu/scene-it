import Testing

@testable import SceneItCore

/// A save that records when it ran and plays scripted outcomes; after the script, saves succeed.
@MainActor
private final class ScriptedSave {
    enum Step {
        case succeed
        case fail(SaveError)
        /// Waits for `release()`, then succeeds.
        case hold
    }

    private let clock: ManualClock
    private var steps: [Step]
    private(set) var times: [ManualClock.Instant] = []
    private var held: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []

    init(clock: ManualClock, _ steps: [Step] = []) {
        self.clock = clock
        self.steps = steps
    }

    func save() async throws(SaveError) {
        times.append(clock.now)
        let step = steps.isEmpty ? .succeed : steps.removeFirst()
        switch step {
        case .succeed:
            return
        case .fail(let error):
            throw error
        case .hold:
            await withCheckedContinuation { continuation in
                held = continuation
                for waiter in holdWaiters { waiter.resume() }
                holdWaiters = []
            }
        }
    }

    func untilHeld() async {
        if held == nil { await withCheckedContinuation { holdWaiters.append($0) } }
    }

    func release() {
        held?.resume()
        held = nil
    }
}

@MainActor
private func makeDriver(_ steps: [ScriptedSave.Step] = []) -> (
    ManualClock, ScriptedSave, AutosaveDriver<ManualClock>
) {
    let clock = ManualClock()
    let script = ScriptedSave(clock: clock, steps)
    let driver = AutosaveDriver(clock: clock, save: script.save)
    return (clock, script, driver)
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AutosaveDriverTests {
    @Test func savesAfterTheIdleDelayOnTheInjectedClock() async {
        let (clock, script, driver) = makeDriver()
        driver.send(.edited)
        clock.advance(by: Interval(clamping: .milliseconds(1500)))
        driver.send(.edited)
        clock.advance(by: .seconds(2))
        await driver.wait { $0 == .clean }
        #expect(script.times == [at(.milliseconds(3500))])
    }

    @Test func aFailedSaveIsRetriedAfterTheBackoff() async {
        let (clock, script, driver) = makeDriver([.fail(diskFull)])
        driver.send(.edited)
        clock.advance(by: .seconds(2))
        await driver.wait { $0.quitDecision == .settled(.askWriter(.saveFailed(diskFull))) }
        #expect(driver.scheduler.failure?.consecutive == 1)
        clock.advance(by: .seconds(2))
        await driver.wait { $0 == .clean }
        #expect(script.times == [at(.seconds(2)), at(.seconds(4))])
    }

    @Test func editsDuringARunningSaveAreSavedNext() async {
        let (clock, script, driver) = makeDriver([.hold])
        driver.send(.edited)
        clock.advance(by: .seconds(2))
        await script.untilHeld()
        driver.send(.edited)
        driver.send(.saveCommand)
        script.release()
        await driver.wait { $0 == .clean }
        #expect(script.times == [at(.seconds(2)), at(.seconds(2))])
    }

    @Test func quittingSavesUnsavedEditsThenTerminates() async {
        let (_, script, driver) = makeDriver()
        driver.send(.edited)
        #expect(await driver.prepareToQuit() == .terminate)
        #expect(script.times == [at(.zero)])
    }

    @Test func quittingWaitsForASaveInFlight() async {
        let (clock, script, driver) = makeDriver([.hold])
        driver.send(.edited)
        clock.advance(by: .seconds(2))
        await script.untilHeld()
        async let verdict = driver.prepareToQuit()
        script.release()
        #expect(await verdict == .terminate)
        #expect(script.times == [at(.seconds(2))])
    }

    @Test func aFailingSaveAtQuitAsksAndRetryCanSucceed() async {
        let (_, script, driver) = makeDriver([.fail(diskFull)])
        driver.send(.edited)
        #expect(await driver.prepareToQuit() == .askWriter(.saveFailed(diskFull)))
        #expect(await driver.prepareToQuit() == .terminate)
        #expect(script.times.count == 2)
    }

    @Test func quittingWhilePausedAsksWithoutSaving() async {
        let (_, script, driver) = makeDriver([.fail(changedOnDisk)])
        driver.send(.edited)
        driver.send(.saveCommand)
        await driver.wait { if case .paused = $0 { true } else { false } }
        #expect(await driver.prepareToQuit() == .askWriter(.changedOnDisk(changedOnDisk)))
        #expect(script.times.count == 1)
    }
}
