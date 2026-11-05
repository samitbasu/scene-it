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
    let deadline = Date.now.addingTimeInterval(5)
    while seen == nil, Date.now < deadline {
        _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
    }
    return seen
}

/// An exception that unwinds a task can't be raised here: the test host would be left corrupt.
/// These tests check the trap is armed and stays quiet wherever the thread's record is sound.
@MainActor
@Suite(.serialized)
struct UnwoundTaskTrapTests {
    @Test func theAppArmsTheTrapOnTheMainRunLoop() throws {
        let observer = try #require(UnwoundTaskTrap.observer, "installed as the app launches")
        #expect(CFRunLoopContainsObserver(CFRunLoopGetMain(), observer, .commonModes))
        #expect(CFRunLoopObserverIsValid(observer))
        #expect(UnwoundTaskTrap.concurrencyImage != nil, "it can tell a job's frames from the rest")
    }

    @Test func aJobIsAJob() async {
        #expect(UnwoundTaskTrap.context == .job)
    }

    @Test func theRunLoopOutsideAnyJobHasNoTask() async {
        #expect(await contextOnTheRunLoop() == .none)
    }

    /// As a modal alert run from a task does: the trap runs at each turn of the inner loop,
    /// where the task is current and its job is on the stack.
    @Test func aRunLoopInsideAJobIsNotAnUnwind() async {
        #expect(contextInANestedRunLoop() == .job)
    }
}
