import CoreFoundation
import Darwin
import MachO
import SceneItCore

/// Stops the app once an Objective-C exception has unwound a Swift task on the main thread
/// (ADR 0026), at the next run-loop activity it observes, normally before the next isolation
/// check.
///
/// HIToolbox catches an exception that escapes the run loop, logs it and carries on, whatever
/// `NSApplicationCrashOnExceptions` says. When the exception came from a task's job, the job
/// runner never restored the thread's record of the current task and executor, which is left
/// pointing into a dead stack frame, and the next isolation check crashes somewhere unrelated
/// (#72, #120).
///
/// Nonisolated, so the check itself makes no isolation check: one would read the dead frame.
nonisolated enum UnwoundTaskTrap {
    /// Whether the thread's record names a task.
    enum TaskPresence {
        case current, absent
    }

    /// What the main thread is running, as far as Swift concurrency is concerned.
    enum TaskContext: Equatable {
        case none
        /// A job, which may be running a run loop of its own, as a modal alert does.
        case job
        /// The thread says a task is running, but no job is: something left the job without
        /// returning through the runner, as an exception does.
        case unwound

        /// `runner` is the code of the image that runs jobs; a job has one of its frames on the
        /// stack, below everything the job calls.
        init(task: TaskPresence, returnAddresses: some Sequence<UInt>, runner: Range<UInt>) {
            switch task {
            case .absent: self = .none
            case .current: self = returnAddresses.contains(where: runner.contains) ? .job : .unwound
            }
        }
    }

    @MainActor private(set) static var observer: CFRunLoopObserver?

    @MainActor static func install() {
        guard observer == nil else { return }
        if runner == nil {
            Log.diagnostics.fault("the job runner's code wasn't found; unwound tasks won't be trapped")
        }
        let activities: CFRunLoopActivity = [.entry, .afterWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, CFIndex.min, check)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        Self.observer = observer
    }

    private static func check(_ observer: CFRunLoopObserver?, _ activity: CFRunLoopActivity) {
        if context == .unwound {
            fatalError("An Objective-C exception unwound a Swift task (ADR 0026)")
        }
    }

    /// `withUnsafeCurrentTask` retains and releases the task it finds. After an unwind that's
    /// still safe: the task never completes, so it's leaked, never freed.
    static var context: TaskContext {
        let task: TaskPresence = withUnsafeCurrentTask { $0 == nil ? .absent : .current }
        guard case .current = task else { return .none }
        guard let runner else { return .job }
        var frames = InlineArray<512, UnsafeMutableRawPointer?>(repeating: nil)
        var span = frames.mutableSpan
        return span.withUnsafeMutableBufferPointer { buffer in
            let count = Int(backtrace(buffer.baseAddress, Int32(buffer.count)))
            // A full buffer may have cut the runner's frame off; a job is the safe guess.
            guard count < buffer.count else { return .job }
            let addresses = buffer.prefix(count).lazy.map { UInt(bitPattern: $0) }
            return TaskContext(task: task, returnAddresses: addresses, runner: runner)
        }
    }

    /// `dlfcn.h`'s `RTLD_DEFAULT`, a cast macro that Swift doesn't import.
    private static var rtldDefault: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: -2) }

    /// The `__TEXT` of `libswift_Concurrency`, where `swift_job_run` lives.
    static let runner: Range<UInt>? = {
        var info = Dl_info()
        guard let symbol = dlsym(rtldDefault, "swift_job_run"), dladdr(symbol, &info) != 0,
            let base = info.dli_fbase
        else { return nil }
        var size: UInt = 0
        guard let text = getsegmentdata(base.assumingMemoryBound(to: mach_header_64.self), "__TEXT", &size),
            size > 0
        else { return nil }
        let start = UInt(bitPattern: text)
        return start..<(start + size)
    }()
}
