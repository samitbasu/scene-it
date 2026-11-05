import CoreFoundation
import Darwin
import Foundation

/// Stops the app as soon as an Objective-C exception has unwound a Swift task on the main
/// thread (ADR 0026).
///
/// HIToolbox catches an exception that escapes the run loop, logs it and carries on, whatever
/// `NSApplicationCrashOnExceptions` says. When the exception came from a task's job, the job
/// runner never restored the thread's record of the current task and executor, which is left
/// pointing into a dead stack frame, and the next actor-isolation check crashes somewhere
/// unrelated (#72, #120). Each time the main run loop turns, the trap looks for that record
/// outside any job.
///
/// Nonisolated, so the check itself makes no isolation check: one would read the dead frame.
nonisolated enum UnwoundTaskTrap {
    /// What the main thread is running, as far as Swift concurrency is concerned.
    enum TaskContext: Equatable {
        case none
        /// A job, which may be running a run loop of its own, as a modal alert does.
        case job
        /// The thread says a task is running, but no job is: an exception unwound it.
        case unwound
    }

    @MainActor private(set) static var observer: CFRunLoopObserver?

    @MainActor static func install() {
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.allActivities.rawValue, true, CFIndex.min, check)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        Self.observer = observer
    }

    private static func check(_ observer: CFRunLoopObserver?, _ activity: CFRunLoopActivity) {
        if context == .unwound {
            fatalError("An Objective-C exception unwound a Swift task (ADR 0026)")
        }
    }

    /// Never dereferences the current task: after an unwind it may have been freed.
    static var context: TaskContext {
        guard withUnsafeCurrentTask(body: { $0 != nil }) else { return .none }
        return jobRunnerIsOnTheStack ? .job : .unwound
    }

    /// The image that runs jobs, `libswift_Concurrency`. Without it the trap never fires.
    static let concurrencyImage: UInt? = {
        var info = Dl_info()
        guard let runner = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_job_run"),
            dladdr(runner, &info) != 0
        else { return nil }
        return UInt(bitPattern: info.dli_fbase)
    }()

    private static var jobRunnerIsOnTheStack: Bool {
        guard let concurrencyImage else { return true }
        return Thread.callStackReturnAddresses.contains { address in
            var info = Dl_info()
            return dladdr(UnsafeRawPointer(bitPattern: address.uintValue), &info) != 0
                && UInt(bitPattern: info.dli_fbase) == concurrencyImage
        }
    }
}
