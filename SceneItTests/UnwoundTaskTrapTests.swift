import AppKit
import Testing

@testable import SceneIt

/// The context a block sees when the main run loop runs it, outside any job.
@MainActor
private func contextOnTheRunLoop() async -> UnwoundTaskTrap.TaskContext {
    await withCheckedContinuation { (done: CheckedContinuation<UnwoundTaskTrap.TaskContext, Never>) in
        RunLoop.main.perform {
            done.resume(returning: UnwoundTaskTrap.context)
        }
    }
}

/// Runs the main run loop from inside the caller's job, as `NSAlert.runModal()` does, until a
/// block it runs has seen the context.
@MainActor
private func contextInANestedRunLoop() -> UnwoundTaskTrap.TaskContext? {
    var seen: UnwoundTaskTrap.TaskContext?
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        MainActor.assumeIsolated { seen = UnwoundTaskTrap.context }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while seen == nil, clock.now < deadline {
        _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
    }
    return seen
}

/// An exception that unwinds a task can't be raised here: the test host would be left corrupt.
/// The decision is tested on made-up stacks, and the trap on the real thread where its record
/// is sound.
@MainActor
@Suite(.serialized)
struct UnwoundTaskTrapTests {
    private let runner: Range<UInt> = 0x1000..<0x2000

    @Test func noTaskIsNone() {
        let stack: [UInt] = [0x1800]
        #expect(UnwoundTaskTrap.TaskContext(task: .absent, returnAddresses: stack, runner: runner) == .none)
    }

    @Test func aTaskWithTheRunnerOnTheStackIsAJob() {
        let stack: [UInt] = [0x9000, 0x1800, 0x500]
        #expect(UnwoundTaskTrap.TaskContext(task: .current, returnAddresses: stack, runner: runner) == .job)
    }

    @Test func aTaskWithoutTheRunnerOnTheStackWasUnwound() {
        let stack: [UInt] = [0x9000, 0x2000, 0xFFF, 0x500]
        #expect(
            UnwoundTaskTrap.TaskContext(task: .current, returnAddresses: stack, runner: runner) == .unwound,
            "the runner's range is half-open")
    }

    @Test func theAppArmsTheTrapOnTheMainRunLoop() throws {
        let observer = try #require(UnwoundTaskTrap.observer, "installed as the app launches")
        #expect(CFRunLoopContainsObserver(CFRunLoopGetMain(), observer, .commonModes))
        #expect(CFRunLoopObserverIsValid(observer))
        #expect(UnwoundTaskTrap.runner?.isEmpty == false, "it knows the job runner's code")
    }

    @Test func aJobIsAJob() async {
        #expect(UnwoundTaskTrap.context == .job)
    }

    @Test func theRunLoopOutsideAnyJobHasNoTask() async {
        #expect(await contextOnTheRunLoop() == .none)
    }

    /// As a modal alert run from a task does: the trap checks each time the inner loop is
    /// entered, where the task is current and its job is on the stack.
    @Test func aRunLoopInsideAJobIsNotAnUnwind() async throws {
        try #require(UnwoundTaskTrap.observer != nil, "precondition: the trap is armed")
        #expect(contextInANestedRunLoop() == .job)
    }
}
