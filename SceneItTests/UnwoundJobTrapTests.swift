import AppKit
import Testing

@testable import SceneIt

/// The context a block sees when the main run loop runs it, outside any job.
@MainActor
private func contextOnTheRunLoop() async -> UnwoundJobTrap.JobContext {
    await withCheckedContinuation { (done: CheckedContinuation<UnwoundJobTrap.JobContext, Never>) in
        RunLoop.main.perform {
            done.resume(returning: UnwoundJobTrap.context)
        }
    }
}

/// Runs the main run loop from inside the caller's job, as `NSAlert.runModal()` does, until a
/// block it runs has seen the context.
@MainActor
private func contextInANestedRunLoop() -> UnwoundJobTrap.JobContext? {
    var seen: UnwoundJobTrap.JobContext?
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        MainActor.assumeIsolated { seen = UnwoundJobTrap.context }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while seen == nil, clock.now < deadline {
        _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
    }
    return seen
}

/// What an isolated deinit run as a job sees.
private struct DeinitJobSight: Sendable {
    let taskRecord: UnwoundJobTrap.JobRecord
    let context: UnwoundJobTrap.JobContext
}

/// Its last reference goes away off the main thread, so its isolated deinit runs as a main-actor
/// job of its own, with no task (#142).
private final class DeinitJobProbe {
    private let seen: CheckedContinuation<DeinitJobSight, Never>

    nonisolated init(_ seen: CheckedContinuation<DeinitJobSight, Never>) {
        self.seen = seen
    }

    isolated deinit {
        let task: UnwoundJobTrap.JobRecord = withUnsafeCurrentTask { $0 == nil ? .clear : .set }
        seen.resume(returning: DeinitJobSight(taskRecord: task, context: UnwoundJobTrap.context))
    }
}

/// An exception that unwinds a job can't be raised here: the test host would be left corrupt.
/// The decision is tested on made-up stacks, and the trap on the real thread where its record
/// is sound.
@MainActor
@Suite(.serialized)
struct UnwoundJobTrapTests {
    private let runner: Range<UInt> = 0x1000..<0x2000

    @Test func aClearRecordOutsideAnyJobIsUsable() {
        #expect(UnwoundJobTrap.Calibration(identityOutsideAnyJob: 0) == .usable)
    }

    /// A runtime that names the main executor outside any job would make every run-loop entry
    /// look like an unwind, so the trap stops reading the record.
    @Test func aSetRecordOutsideAnyJobIsUnusable() {
        #expect(UnwoundJobTrap.Calibration(identityOutsideAnyJob: 0x1_0000_4000) == .unusable)
    }

    @Test func noRecordIsNone() {
        let stack: [UInt] = [0x1800]
        #expect(UnwoundJobTrap.JobContext(record: .clear, returnAddresses: stack, runner: runner) == .none)
    }

    @Test func aRecordWithTheRunnerOnTheStackIsAJob() {
        let stack: [UInt] = [0x9000, 0x1800, 0x500]
        #expect(UnwoundJobTrap.JobContext(record: .set, returnAddresses: stack, runner: runner) == .job)
    }

    @Test func aRecordWithoutTheRunnerOnTheStackWasUnwound() {
        let stack: [UInt] = [0x9000, 0x2000, 0xFFF, 0x500]
        #expect(
            UnwoundJobTrap.JobContext(record: .set, returnAddresses: stack, runner: runner) == .unwound,
            "the runner's range is half-open")
    }

    @Test func theAppArmsTheTrapOnTheMainRunLoop() throws {
        let observer = try #require(UnwoundJobTrap.observer, "installed as the app launches")
        #expect(CFRunLoopContainsObserver(CFRunLoopGetMain(), observer, .commonModes))
        #expect(CFRunLoopObserverIsValid(observer))
        #expect(UnwoundJobTrap.runner?.isEmpty == false, "it knows the job runner's code")
        #expect(UnwoundJobTrap.executorIdentity != nil, "it reads the executor record, calibrated as usable")
    }

    @Test func aJobIsAJob() async {
        #expect(UnwoundJobTrap.context == .job)
    }

    /// The trap reads the executor record too, so an unwound deinit job is caught (#142).
    @Test func anIsolatedDeinitJobIsAJob() async {
        let sight = await withCheckedContinuation { seen in
            Task.detached { _ = DeinitJobProbe(seen) }
        }
        #expect(sight.taskRecord == .clear, "precondition: the deinit ran as a job without a task")
        #expect(sight.context == .job)
    }

    @Test func theRunLoopOutsideAnyJobHasNoTask() async {
        #expect(await contextOnTheRunLoop() == .none)
    }

    /// As a modal alert run from a task does: the trap checks each time the inner loop is
    /// entered, where the task is current and its job is on the stack.
    @Test func aRunLoopInsideAJobIsNotAnUnwind() async throws {
        try #require(UnwoundJobTrap.observer != nil, "precondition: the trap is armed")
        #expect(contextInANestedRunLoop() == .job)
    }
}
